#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# Tests for per-adapter integrity contract declarations (issue #441, Step 8a).
#
# Decision 6 (per-adapter integrity exemptions):
#   standard adapter  — expects pass-blocks 1, 2, and 3 in the prosecution ledger
#   lite adapter      — expects pass-block 1 only
#   judge-only        — exempt (re-review scope; no new prosecution)
#   proxy-github      — exempt (external review intake; single proxy pass)
#
# The integrity contract is declared in YAML frontmatter of each adapter .md file
# under the `integrity-contract:` key.

BeforeAll {
    $script:RepoRoot     = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
    $script:AdaptersPath = Join-Path $script:RepoRoot 'skills/adversarial-review/adapters'
    $script:LibPath      = Join-Path $script:RepoRoot '.github/scripts/lib/frame-credit-ledger-core.ps1'

    if (Test-Path $script:LibPath) {
        . $script:LibPath
    }

    # ---------------------------------------------------------------------------
    # Frontmatter YAML parser (regex-based — no YAML module required)
    # Handles the narrow schema used in adapter frontmatter:
    #   integrity-contract:
    #     pass-blocks: [1, 2, 3]
    #     exempt: true|false
    #     exempt-reason: "..."
    # ---------------------------------------------------------------------------

    function script:Get-AdapterIntegrityContract {
        param(
            [Parameter(Mandatory)]
            [string]$AdapterPath
        )

        if (-not (Test-Path $AdapterPath)) {
            return $null
        }

        $content = Get-Content $AdapterPath -Raw

        # Extract YAML frontmatter between the opening and closing --- delimiters.
        if ($content -notmatch '(?ms)^---\s*\r?\n(?<fm>.*?)\r?\n---') {
            return $null
        }

        $fm = $matches['fm']
        if ($fm -notmatch 'integrity-contract:') {
            return $null
        }

        # Parse pass-blocks: [...] from the indented section.
        $passBlocks = @()
        if ($fm -match '(?ms)integrity-contract:.*?pass-blocks:\s*\[(?<blocks>[^\]]*)\]') {
            $blockStr = $matches['blocks']
            $passBlocks = @(
                $blockStr -split '[,\s]+' |
                Where-Object { $_ -match '^\d+$' } |
                ForEach-Object { [int]$_ }
            )
        }

        # Parse exempt: true|false from the indented section.
        $exempt = $false
        if ($fm -match '(?ms)integrity-contract:.*?exempt:\s*(?<val>true|false)') {
            $exempt = [System.Boolean]::Parse($matches['val'].Trim())
        }

        # Parse optional exempt-reason.
        $exemptReason = $null
        if ($fm -match '(?ms)integrity-contract:.*?exempt-reason:\s*"(?<reason>[^"]*)"') {
            $exemptReason = $matches['reason']
        }

        return [pscustomobject]@{
            PassBlocks   = $passBlocks
            Exempt       = $exempt
            ExemptReason = $exemptReason
        }
    }
}

# ---------------------------------------------------------------------------
# Section 1 — adapter frontmatter contract tests
# ---------------------------------------------------------------------------

Describe 'Per-adapter integrity contract declarations (Step 8a — Decision 6)' {

    It 'standard adapter declares integrity-contract with pass-blocks [1, 2, 3]' {
        $contract = script:Get-AdapterIntegrityContract `
            (Join-Path $script:AdaptersPath 'standard.md')

        $contract             | Should -Not -BeNullOrEmpty -Because 'standard.md must have integrity-contract frontmatter'
        $contract.Exempt      | Should -Be $false -Because 'standard adapter is not exempt'
        $contract.PassBlocks  | Should -Be @(1, 2, 3) -Because 'standard review runs all three prosecution passes'
    }

    It 'lite adapter declares integrity-contract with pass-blocks [1]' {
        $contract = script:Get-AdapterIntegrityContract `
            (Join-Path $script:AdaptersPath 'lite.md')

        $contract             | Should -Not -BeNullOrEmpty -Because 'lite.md must have integrity-contract frontmatter'
        $contract.Exempt      | Should -Be $false -Because 'lite adapter is not exempt'
        $contract.PassBlocks  | Should -Be @(1) -Because 'lite review runs only one compact prosecution pass'
    }

    It 'judge-only adapter declares exempt=true in integrity-contract' {
        $contract = script:Get-AdapterIntegrityContract `
            (Join-Path $script:AdaptersPath 'judge-only.md')

        $contract        | Should -Not -BeNullOrEmpty -Because 'judge-only.md must have integrity-contract frontmatter'
        $contract.Exempt | Should -Be $true  -Because 'judge-only has no prosecution phase'
    }

    It 'proxy-github adapter declares exempt=true in integrity-contract' {
        $contract = script:Get-AdapterIntegrityContract `
            (Join-Path $script:AdaptersPath 'proxy-github.md')

        $contract        | Should -Not -BeNullOrEmpty -Because 'proxy-github.md must have integrity-contract frontmatter'
        $contract.Exempt | Should -Be $true  -Because 'proxy-github replaces multi-pass with a single proxy pass'
    }

    It 'standard adapter declares more pass-blocks than lite adapter' {
        $standard = script:Get-AdapterIntegrityContract (Join-Path $script:AdaptersPath 'standard.md')
        $lite     = script:Get-AdapterIntegrityContract (Join-Path $script:AdaptersPath 'lite.md')

        $standard.PassBlocks.Count | Should -BeGreaterThan $lite.PassBlocks.Count
    }

    It 'exempt adapters declare an empty pass-blocks list' {
        $judgeOnly   = script:Get-AdapterIntegrityContract (Join-Path $script:AdaptersPath 'judge-only.md')
        $proxyGithub = script:Get-AdapterIntegrityContract (Join-Path $script:AdaptersPath 'proxy-github.md')

        $judgeOnly.PassBlocks.Count   | Should -Be 0
        $proxyGithub.PassBlocks.Count | Should -Be 0
    }

    It 'exempt adapters carry a non-empty exempt-reason' {
        $judgeOnly   = script:Get-AdapterIntegrityContract (Join-Path $script:AdaptersPath 'judge-only.md')
        $proxyGithub = script:Get-AdapterIntegrityContract (Join-Path $script:AdaptersPath 'proxy-github.md')

        [string]::IsNullOrWhiteSpace($judgeOnly.ExemptReason)   | Should -Be $false
        [string]::IsNullOrWhiteSpace($proxyGithub.ExemptReason) | Should -Be $false
    }
}

# ---------------------------------------------------------------------------
# Section 2 — adversarial-review SKILL.md integrity contract table
# ---------------------------------------------------------------------------

Describe 'adversarial-review SKILL.md integrity contract table (Step 8a)' {

    BeforeAll {
        $script:SkillPath = Join-Path $script:RepoRoot 'skills/adversarial-review/SKILL.md'
        $script:Skill     = Get-Content $script:SkillPath -Raw -ErrorAction SilentlyContinue
    }

    It 'SKILL.md contains an integrity contract section' {
        $script:Skill | Should -Match 'Integrity Contract' -Because 'SKILL.md must document the per-adapter integrity contract'
    }

    It 'SKILL.md names the standard adapter as expecting three pass-blocks' {
        $script:Skill | Should -Match 'standard' -Because 'SKILL.md must name the standard adapter'
        # The table should reference 1, 2, 3 pass-blocks for standard.
        $script:Skill | Should -Match '1.*2.*3|pass.blocks.*1.*2.*3|\[1, 2, 3\]' -Because 'standard must show 3 pass-blocks'
    }

    It 'SKILL.md names the lite adapter as expecting one pass-block' {
        $script:Skill | Should -Match 'lite' -Because 'SKILL.md must name the lite adapter'
    }

    It 'SKILL.md names judge-only and proxy-github as exempt' {
        $script:Skill | Should -Match 'exempt' -Because 'SKILL.md must document the exempt concept'
        $script:Skill | Should -Match 'judge.only|judge-only' -Because 'SKILL.md must name judge-only adapter'
        $script:Skill | Should -Match 'proxy.github|proxy-github' -Because 'SKILL.md must name proxy-github adapter'
    }
}

# ---------------------------------------------------------------------------
# Section 3 — Build-ReviewCreditRow (Step 8b — Decision 2 + M1 emission)
# ---------------------------------------------------------------------------

Describe 'Build-ReviewCreditRow (Step 8b — v4 review credit row construction)' {

    BeforeAll {
    # Fixture judge-rulings comment: two findings, one sustained (medium), one defense-sustained.
    $script:JudgeRulingsAllPassed = @'
### Adversarial Review Score Summary

| Finding | Pass | Prosecution (severity, pts) | Defense verdict | Ruling | Confidence | Points |
| ------- | ---- | --------------------------- | --------------- | ------ | ---------- | ------ |
| F1: Minor doc drift | 1 | low (1 pt) | disproved | ❌ Defense sustained | high | D+1 |
| F2: Missing type guard | 2 | medium (5 pts) | conceded | ✅ Sustained | high | P+5 |

<!-- judge-rulings
- id: F1
  judge_ruling: defense-sustained
  judge_confidence: high
  points_awarded: D+1
- id: F2
  judge_ruling: sustained
  judge_confidence: high
  points_awarded: P+5
-->
'@

    # Fixture with a sustained HIGH finding (P+10) → should produce status=failed.
    $script:JudgeRulingsHighSustained = @'
<!-- judge-rulings
- id: F1
  judge_ruling: sustained
  judge_confidence: high
  points_awarded: P+10
- id: F2
  judge_ruling: defense-sustained
  judge_confidence: medium
  points_awarded: D+5
-->
'@

    # Fixture with all defense-sustained.
    $script:JudgeRulingsAllDefense = @'
<!-- judge-rulings
- id: F1
  judge_ruling: defense-sustained
  judge_confidence: high
  points_awarded: D+5
-->
'@
    }


    It 'returns a credit row with all required v4 fields' {
        $row = Build-ReviewCreditRow -JudgeRulingsComment $script:JudgeRulingsAllPassed `
            -AdapterName 'standard'

        $row | Should -Not -BeNullOrEmpty
        $row.PSObject.Properties.Name | Should -Contain 'port'
        $row.PSObject.Properties.Name | Should -Contain 'adapter'
        $row.PSObject.Properties.Name | Should -Contain 'status'
        $row.PSObject.Properties.Name | Should -Contain 'run_index'
        $row.PSObject.Properties.Name | Should -Contain 'evidence'
        $row.PSObject.Properties.Name | Should -Contain 'judge-score'
        $row.PSObject.Properties.Name | Should -Contain 'integrity-check'
    }

    It 'port is always review' {
        $row = Build-ReviewCreditRow -JudgeRulingsComment $script:JudgeRulingsAllPassed
        $row.port | Should -Be 'review'
    }

    It 'adapter defaults to standard' {
        $row = Build-ReviewCreditRow -JudgeRulingsComment $script:JudgeRulingsAllPassed
        $row.adapter | Should -Be 'standard'
    }

    It 'run_index defaults to 1' {
        $row = Build-ReviewCreditRow -JudgeRulingsComment $script:JudgeRulingsAllPassed
        $row.run_index | Should -Be 1
    }

    It 'run_index is overridable via parameter' {
        $row = Build-ReviewCreditRow -JudgeRulingsComment $script:JudgeRulingsAllPassed `
            -RunIndex 3
        $row.run_index | Should -Be 3
    }

    It 'status is passed when no P+10 finding is sustained' {
        $row = Build-ReviewCreditRow -JudgeRulingsComment $script:JudgeRulingsAllPassed
        $row.status | Should -Be 'passed'
    }

    It 'status is failed when a P+10 finding is sustained' {
        $row = Build-ReviewCreditRow -JudgeRulingsComment $script:JudgeRulingsHighSustained
        $row.status | Should -Be 'failed'
    }

    It 'status is passed when all findings are defense-sustained' {
        $row = Build-ReviewCreditRow -JudgeRulingsComment $script:JudgeRulingsAllDefense
        $row.status | Should -Be 'passed'
    }

    It 'judge-score.findings list contains one entry per judge-rulings row' {
        $row = Build-ReviewCreditRow -JudgeRulingsComment $script:JudgeRulingsAllPassed
        @($row.'judge-score'.findings).Count | Should -Be 2
    }

    It 'judge-score.findings entries carry id and ruling fields' {
        $row = Build-ReviewCreditRow -JudgeRulingsComment $script:JudgeRulingsAllPassed
        $f1 = $row.'judge-score'.findings | Where-Object { $_.id -eq 'F1' }
        $f1 | Should -Not -BeNullOrEmpty
        $f1.ruling | Should -Be 'defense-sustained'
    }

    It 'integrity-check.pass-blocks is [1,2,3] for standard adapter' {
        $row = Build-ReviewCreditRow -JudgeRulingsComment $script:JudgeRulingsAllPassed `
            -AdapterName 'standard' -AdaptersDir $script:AdaptersPath

        @($row.'integrity-check'.'pass-blocks') | Should -Be @(1, 2, 3)
    }

    It 'integrity-check.pass-blocks is [1] for lite adapter' {
        $row = Build-ReviewCreditRow -JudgeRulingsComment $script:JudgeRulingsAllPassed `
            -AdapterName 'lite' -AdaptersDir $script:AdaptersPath

        @($row.'integrity-check'.'pass-blocks') | Should -Be @(1)
    }

    It 'integrity-check.status is not-applicable for exempt adapters (judge-only)' {
        $row = Build-ReviewCreditRow -JudgeRulingsComment $script:JudgeRulingsAllDefense `
            -AdapterName 'judge-only' -AdaptersDir $script:AdaptersPath

        $row.'integrity-check'.status | Should -Be 'not-applicable'
    }

    It 'evidence is a non-empty string' {
        $row = Build-ReviewCreditRow -JudgeRulingsComment $script:JudgeRulingsAllPassed
        [string]::IsNullOrWhiteSpace($row.evidence) | Should -Be $false
    }

    It 'custom evidence string is used when provided' {
        $customEvidence = 'judge ruling: keep — all findings minor or disproved'
        $row = Build-ReviewCreditRow -JudgeRulingsComment $script:JudgeRulingsAllPassed `
            -Evidence $customEvidence
        $row.evidence | Should -Be $customEvidence
    }

    It 'RunIndex=0 is preserved as-is and does not default to 1 (L5 fix — issue #441)' {
        # PowerShell falsy-0 coercion footgun: explicit RunIndex=0 must not be silently
        # replaced by the default value of 1. We verify the field carries 0 when supplied.
        $row = Build-ReviewCreditRow -JudgeRulingsComment $script:JudgeRulingsAllPassed `
            -RunIndex 0
        $row.run_index | Should -Be 0 -Because 'RunIndex=0 is a caller-supplied value and must not be overwritten by the default'
    }

    It 'P+100 points_awarded does not trigger failed status (M1 regex anchor fix — issue #441)' {
        # Regression guard: the P\+10\b boundary fix must prevent P+100 from matching P+10.
        $highPointsComment = @'
<!-- judge-rulings
- id: F1
  judge_ruling: sustained
  judge_confidence: high
  points_awarded: P+100
-->
'@
        $row = Build-ReviewCreditRow -JudgeRulingsComment $highPointsComment
        # P+100 should NOT be interpreted as Critical/High (P+10) — status should stay passed.
        $row.status | Should -Be 'passed' -Because 'P+100 must not match the P+10 boundary pattern after the word-boundary anchor fix'
    }

    It 'P+1000 points_awarded does not trigger failed status (M1 regex anchor fix — issue #441)' {
        $veryHighPointsComment = @'
<!-- judge-rulings
- id: F1
  judge_ruling: sustained
  judge_confidence: high
  points_awarded: P+1000
-->
'@
        $row = Build-ReviewCreditRow -JudgeRulingsComment $veryHighPointsComment
        $row.status | Should -Be 'passed' -Because 'P+1000 must not match the P+10 boundary pattern'
    }
}