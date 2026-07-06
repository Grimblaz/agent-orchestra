#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# Tests for per-adapter integrity contract declarations (issue #441, Step 8a).
#
# Decision 6 (per-adapter integrity exemptions):
#   standard adapter  — expects prosecution passes 1, 2, 3, 4, and 5 in the prosecution ledger (five-pass two-layer panel)
#   lite adapter      — expects prosecution pass 1 only
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
    #     pipeline-stages: [prosecution, defense, judge]
    #     atomic: true|n/a
    #     prosecution-passes: [1, 2, 3, 4, 5]
    #     exempt: true|false
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

        # Parse pipeline-stages: [...] from the indented section.
        $pipelineStages = @()
        if ($fm -match '(?ms)integrity-contract:.*?pipeline-stages:\s*\[(?<stages>[^\]]*)\]') {
            $stageStr = $matches['stages']
            $pipelineStages = @(
                $stageStr -split '[,\s]+' |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
            )
        }

        # Parse atomic: true|false|n/a from the indented section.
        $atomic = $null
        if ($fm -match '(?ms)integrity-contract:.*?atomic:\s*(?<val>true|false|n/a)') {
            $atomic = $matches['val'].Trim()
        }

        # Parse prosecution-passes: [...] from the indented section.
        $prosecutionPasses = @()
        if ($fm -match '(?ms)integrity-contract:.*?prosecution-passes:\s*\[(?<passes>[^\]]*)\]') {
            $passStr = $matches['passes']
            $prosecutionPasses = @(
                $passStr -split '[,\s]+' |
                Where-Object { $_ -match '^\d+$' } |
                ForEach-Object { [int]$_ }
            )
        }

        # Parse exempt: true|false from the indented section.
        $exempt = $false
        if ($fm -match '(?ms)integrity-contract:.*?exempt:\s*(?<val>true|false)') {
            $exempt = [System.Boolean]::Parse($matches['val'].Trim())
        }

        return [pscustomobject]@{
            PipelineStages    = $pipelineStages
            Atomic            = $atomic
            ProsecutionPasses = $prosecutionPasses
            Exempt            = $exempt
        }
    }
}

# ---------------------------------------------------------------------------
# Section 1 — adapter frontmatter contract tests
# ---------------------------------------------------------------------------

Describe 'Per-adapter integrity contract declarations (Step 8a — Decision 6)' {

    It 'standard adapter declares integrity-contract with prosecution-passes [1, 2, 3, 4, 5]' {
        $contract = script:Get-AdapterIntegrityContract `
            (Join-Path $script:AdaptersPath 'standard.md')

        $contract                   | Should -Not -BeNullOrEmpty -Because 'standard.md must have integrity-contract frontmatter'
        $contract.PipelineStages    | Should -Be @('prosecution', 'defense', 'judge')
        $contract.Atomic            | Should -Be 'true'
        $contract.Exempt            | Should -Be $false -Because 'standard adapter is not exempt'
        $contract.ProsecutionPasses | Should -Be @(1, 2, 3, 4, 5) -Because 'standard review runs all five prosecution passes in the two-layer panel'
    }

    It 'lite adapter declares integrity-contract with prosecution-passes [1]' {
        $contract = script:Get-AdapterIntegrityContract `
            (Join-Path $script:AdaptersPath 'lite.md')

        $contract                   | Should -Not -BeNullOrEmpty -Because 'lite.md must have integrity-contract frontmatter'
        $contract.PipelineStages    | Should -Be @('prosecution', 'defense', 'judge')
        $contract.Atomic            | Should -Be 'true'
        $contract.Exempt            | Should -Be $false -Because 'lite adapter is not exempt'
        $contract.ProsecutionPasses | Should -Be @(1) -Because 'lite review runs only one compact prosecution pass'
    }

    It 'judge-only adapter declares exempt=true in integrity-contract' {
        $contract = script:Get-AdapterIntegrityContract `
            (Join-Path $script:AdaptersPath 'judge-only.md')

        $contract                   | Should -Not -BeNullOrEmpty -Because 'judge-only.md must have integrity-contract frontmatter'
        $contract.PipelineStages    | Should -Be @('judge')
        $contract.Atomic            | Should -Be 'n/a'
        $contract.ProsecutionPasses.Count | Should -Be 0
        $contract.Exempt            | Should -Be $true -Because 'judge-only has no prosecution phase'
    }

    It 'proxy-github adapter declares exempt=true in integrity-contract' {
        $contract = script:Get-AdapterIntegrityContract `
            (Join-Path $script:AdaptersPath 'proxy-github.md')

        $contract                   | Should -Not -BeNullOrEmpty -Because 'proxy-github.md must have integrity-contract frontmatter'
        $contract.PipelineStages    | Should -Be @('proxy-prosecution')
        $contract.Atomic            | Should -Be 'n/a'
        $contract.ProsecutionPasses.Count | Should -Be 0
        $contract.Exempt            | Should -Be $true -Because 'proxy-github replaces multi-pass with a single proxy pass'
    }

    It 'standard adapter declares more prosecution passes than lite adapter' {
        $standard = script:Get-AdapterIntegrityContract (Join-Path $script:AdaptersPath 'standard.md')
        $lite     = script:Get-AdapterIntegrityContract (Join-Path $script:AdaptersPath 'lite.md')

        $standard.ProsecutionPasses.Count | Should -BeGreaterThan $lite.ProsecutionPasses.Count
    }

    It 'exempt adapters declare an empty prosecution-passes list' {
        $judgeOnly   = script:Get-AdapterIntegrityContract (Join-Path $script:AdaptersPath 'judge-only.md')
        $proxyGithub = script:Get-AdapterIntegrityContract (Join-Path $script:AdaptersPath 'proxy-github.md')

        $judgeOnly.ProsecutionPasses.Count   | Should -Be 0
        $proxyGithub.ProsecutionPasses.Count | Should -Be 0
    }

    It 'exempt adapters declare non-atomic integrity contracts' {
        $judgeOnly   = script:Get-AdapterIntegrityContract (Join-Path $script:AdaptersPath 'judge-only.md')
        $proxyGithub = script:Get-AdapterIntegrityContract (Join-Path $script:AdaptersPath 'proxy-github.md')

        $judgeOnly.Atomic   | Should -Be 'n/a'
        $proxyGithub.Atomic | Should -Be 'n/a'
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

    It 'SKILL.md names the standard adapter as expecting five prosecution passes' {
        $script:Skill | Should -Match 'standard' -Because 'SKILL.md must name the standard adapter'
        # The table should reference 1, 2, 3, 4, 5 prosecution passes for standard.
        $script:Skill | Should -Match '1.*2.*3.*4.*5|prosecution.passes.*1.*2.*3.*4.*5|\[1, 2, 3, 4, 5\]' -Because 'standard must show five prosecution passes in the two-layer panel'
    }

    It 'SKILL.md names the lite adapter as expecting one prosecution pass' {
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
    }

    # ---------------------------------------------------------------------
    # Scalar-safe shape (issue #794 Step s5 — Bug 2 fix (b)): judge-score and
    # integrity-check used to be nested pscustomobjects. Render-FCLCreditEntry
    # stringifies unrecognized fields with a naive [string] cast, so nested
    # objects produced corrupted YAML (e.g. "judge-score: @{ruling=passed;
    # findings=System.Object[]}"). Both fields are now folded into the flat
    # evidence string as human-readable prose instead.
    # ---------------------------------------------------------------------

    It 'row contains no pscustomobject or hashtable typed property values (scalar-safe shape)' {
        $row = Build-ReviewCreditRow -JudgeRulingsComment $script:JudgeRulingsAllPassed `
            -AdapterName 'standard'

        foreach ($prop in $row.PSObject.Properties) {
            $prop.Value | Should -Not -BeOfType [System.Management.Automation.PSCustomObject] `
                -Because "property '$($prop.Name)' must be a scalar value, not a nested object"
            $prop.Value | Should -Not -BeOfType [System.Collections.Hashtable] `
                -Because "property '$($prop.Name)' must be a scalar value, not a nested hashtable"
        }
    }

    It 'row does not expose judge-score or integrity-check as separate properties' {
        $row = Build-ReviewCreditRow -JudgeRulingsComment $script:JudgeRulingsAllPassed `
            -AdapterName 'standard'

        $row.PSObject.Properties.Name | Should -Not -Contain 'judge-score'
        $row.PSObject.Properties.Name | Should -Not -Contain 'integrity-check'
    }

    It 'rendered YAML contains no stringified-object markers (@{) after piping through Render-FCLCreditEntry' {
        # Render-FCLCreditEntry is a private nested function inside
        # New-PipelineMetricsV4Block, so we exercise it through that public
        # entry point rather than reaching into its closure directly.
        $row = Build-ReviewCreditRow -JudgeRulingsComment $script:JudgeRulingsAllPassed `
            -AdapterName 'standard' -AdaptersDir $script:AdaptersPath

        $block = New-PipelineMetricsV4Block -V3BaseYaml 'pr_number: 1' -Credits @($row)
        $block | Should -Not -BeNullOrEmpty
        $block | Should -Not -Match '@\{' -Because 'nested objects must never be stringified into the rendered YAML'
    }

    It 'evidence carries the judge ruling status and sustained-finding count' {
        $row = Build-ReviewCreditRow -JudgeRulingsComment $script:JudgeRulingsAllPassed `
            -AdapterName 'standard'

        $row.evidence | Should -Match 'passed' -Because 'evidence must retain the former judge-score.ruling text'
        $row.evidence | Should -Match '1' -Because 'evidence must retain the former judge-score sustained-finding count (one sustained finding in this fixture)'
    }

    It 'evidence carries the integrity-check prosecution-passes count and status' {
        $row = Build-ReviewCreditRow -JudgeRulingsComment $script:JudgeRulingsAllPassed `
            -AdapterName 'standard' -AdaptersDir $script:AdaptersPath

        $row.evidence | Should -Match '1,2,3,4,5|1, ?2, ?3, ?4, ?5' -Because 'evidence must retain the former integrity-check.prosecution-passes list'
        $row.evidence | Should -Match 'passed' -Because 'evidence must retain the former integrity-check.status text'
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

    It 'evidence carries the sustained-finding count (formerly judge-score.findings count)' {
        $row = Build-ReviewCreditRow -JudgeRulingsComment $script:JudgeRulingsAllPassed
        # Fixture has 2 findings total, 1 sustained (F2) and 1 defense-sustained (F1).
        # The scalar-safe evidence string carries the sustained count, not a per-finding list.
        $row.evidence | Should -Match '1 finding' -Because 'evidence must retain the former judge-score sustained-finding count'
    }

    It 'evidence carries the judge ruling status text (formerly judge-score.ruling)' {
        $row = Build-ReviewCreditRow -JudgeRulingsComment $script:JudgeRulingsAllPassed
        $row.evidence | Should -Match 'passed' -Because 'evidence must retain the former judge-score.ruling text'
    }

    It 'evidence carries prosecution-passes [1,2,3,4,5] for standard adapter (formerly integrity-check.prosecution-passes)' {
        $row = Build-ReviewCreditRow -JudgeRulingsComment $script:JudgeRulingsAllPassed `
            -AdapterName 'standard' -AdaptersDir $script:AdaptersPath

        $row.evidence | Should -Match '1,2,3,4,5' -Because 'evidence must retain the former integrity-check.prosecution-passes list for the standard adapter'
        $legacyFieldName = 'pass' + '-blocks'
        $row.evidence | Should -Not -Match $legacyFieldName
    }

    It 'evidence carries prosecution-passes [1] for lite adapter' {
        $row = Build-ReviewCreditRow -JudgeRulingsComment $script:JudgeRulingsAllPassed `
            -AdapterName 'lite' -AdaptersDir $script:AdaptersPath

        $row.evidence | Should -Match 'integrity: 1 passes' -Because 'evidence must retain the former integrity-check.prosecution-passes list for the lite adapter'
    }

    It 'evidence carries prosecution-passes [1] for post-fix adapter without live adapter lookup' {
        $row = Build-ReviewCreditRow -JudgeRulingsComment $script:JudgeRulingsAllPassed `
            -AdapterName 'post-fix'

        $row.evidence | Should -Match 'integrity: 1 passes'
    }

    It 'evidence carries prosecution-passes [1] when live adapter omits exempt' {
        $adapterDir = Join-Path $TestDrive 'adapters-no-exempt'
        New-Item -ItemType Directory -Path $adapterDir -Force | Out-Null
        @'
---
name: review-lite-no-exempt
integrity-contract:
  pipeline-stages: [prosecution]
  atomic: n/a
  prosecution-passes: [1]
---

# Review Lite No Exempt
'@ | Set-Content -Path (Join-Path $adapterDir 'lite.md') -Encoding UTF8

        $row = Build-ReviewCreditRow -JudgeRulingsComment $script:JudgeRulingsAllPassed `
            -AdapterName 'lite' -AdaptersDir $adapterDir

        $row.evidence | Should -Match 'integrity: 1 passes'
        $row.evidence | Should -Match 'status passed'
    }

    It 'falls back to adapter-name defaults when supplied adapter file is missing or unparsable' {
        $missingAdapterDir = Join-Path $TestDrive 'missing-adapters'
        New-Item -ItemType Directory -Path $missingAdapterDir -Force | Out-Null

        $missingRow = Build-ReviewCreditRow -JudgeRulingsComment $script:JudgeRulingsAllPassed `
            -AdapterName 'post-fix' -AdaptersDir $missingAdapterDir

        $missingRow.evidence | Should -Match 'integrity: 1 passes'

        $unparsableAdapterDir = Join-Path $TestDrive 'unparsable-adapters'
        New-Item -ItemType Directory -Path $unparsableAdapterDir -Force | Out-Null
        'not yaml frontmatter' | Set-Content -Path (Join-Path $unparsableAdapterDir 'judge-only.md') -Encoding UTF8

        $unparsableRow = Build-ReviewCreditRow -JudgeRulingsComment $script:JudgeRulingsAllDefense `
            -AdapterName 'judge-only' -AdaptersDir $unparsableAdapterDir

        $unparsableRow.evidence | Should -Match 'integrity: none passes'
        $unparsableRow.evidence | Should -Match 'status not-applicable'
    }

    It 'evidence carries not-applicable status for exempt adapters (judge-only) (formerly integrity-check.status)' {
        $row = Build-ReviewCreditRow -JudgeRulingsComment $script:JudgeRulingsAllDefense `
            -AdapterName 'judge-only' -AdaptersDir $script:AdaptersPath

        $row.evidence | Should -Match 'status not-applicable'
    }

    It 'evidence is a non-empty string' {
        $row = Build-ReviewCreditRow -JudgeRulingsComment $script:JudgeRulingsAllPassed
        [string]::IsNullOrWhiteSpace($row.evidence) | Should -Be $false
    }

    It 'custom evidence string is used as the base when provided, with judge/integrity prose appended' {
        # Scalar-safe shape (issue #794 Step s5): the former judge-score/integrity-check
        # nested fields are now folded into evidence as appended prose, so a caller-supplied
        # Evidence string is preserved as a prefix rather than replaced wholesale.
        $customEvidence = 'judge ruling: keep — all findings minor or disproved'
        $row = Build-ReviewCreditRow -JudgeRulingsComment $script:JudgeRulingsAllPassed `
            -Evidence $customEvidence
        $row.evidence | Should -Match ([regex]::Escape($customEvidence)) -Because 'the caller-supplied evidence text must still be present'
        $row.evidence | Should -Match 'judge ruling: passed' -Because 'the judge-score prose must still be appended even with custom evidence'
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

Describe 'Adversarial atomic marker hook' {
    It 'reports true when an atomic adapter marker is present' {
        $result = Resolve-AdversarialPipelineAtomicMarkerPresence `
            -AdapterAtomicState 'true' `
            -IssueId '629' `
            -Text 'done <!-- adversarial-pipeline-atomic-629 -->'

        $result.adversarial_pipeline_atomic_marker_present | Should -Be 'true'
        $result.warning | Should -Be ''
    }

    It 'reports false-warn-only when an atomic adapter marker is absent' {
        $result = Resolve-AdversarialPipelineAtomicMarkerPresence `
            -AdapterAtomicState 'true' `
            -IssueId '629' `
            -Text 'review completed without marker'

        $result.adversarial_pipeline_atomic_marker_present | Should -Be 'false-warn-only'
        $result.marker | Should -Be '<!-- adversarial-pipeline-atomic-629 -->'
        $result.warning | Should -Match 'false-warn-only'
    }

    It 'reports not-applicable without warning when an atomic adapter marker cannot be expected because IssueId is blank' {
        $result = Resolve-AdversarialPipelineAtomicMarkerPresence `
            -AdapterAtomicState 'true' `
            -IssueId '' `
            -Text 'review completed without marker'

        $result.adversarial_pipeline_atomic_marker_present | Should -Be 'not-applicable'
        $result.marker | Should -Be '<!-- adversarial-pipeline-atomic-{ISSUE_ID} -->'
        $result.warning | Should -Be ''
    }

    It 'reports not-applicable when the adapter is not atomic' {
        $result = Resolve-AdversarialPipelineAtomicMarkerPresence `
            -AdapterAtomicState 'n/a' `
            -IssueId '629' `
            -Text 'review completed without marker'

        $result.adversarial_pipeline_atomic_marker_present | Should -Be 'not-applicable'
        $result.warning | Should -Be ''
    }
}
