# Requires -Version 7.0
# Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    RED-phase test for issue #784 (coverage-first prosecution rewrite). Pins the
    literal prose that Step 3 (GREEN) must introduce, and pins the removal of the
    old downgrade-or-omit escape hatch.

.DESCRIPTION
    Five assertions, mirroring the directive-pinning pattern of
    reporting-economy.Tests.ps1 (here-string fixtures, normalized content
    comparison, -Because on every assertion):

      (a) skills/adversarial-review/SKILL.md no longer contains the exact sentence
          "If the failure mode cannot be stated clearly, downgrade the item or
          omit it." (currently present at line 79). The distinct gotcha-row phrase
          "downgrade the item before output" (line ~348) must NOT be matched by
          this assertion's regex — the full unique sentence is used, not a bare
          "downgrade the item" substring.

      (b) SKILL.md section "### 2. Apply Evidence Standards" contains, after the
          Step 3 rewrite, an omission scope tied to "no statable failure mode"
          co-located with "pure noise", and a tagging requirement using the verb
          "tagged" for confidence + severity.

      (c) SKILL.md section "### 4. Emit a Usable Ledger" contains the
          coverage-vs-economy split: "orthogonal" co-located with "economy" and
          "coverage".

      (d) agents/Code-Critic.agent.md's ## Core Principles section contains
          coverage-first language (does not assert bullet position — that
          structural invariant belongs to reporting-economy.Tests.ps1).

      (e) skills/review-judgment/SKILL.md contains the phrase "filter of record"
          naming the judge as filter of record for coverage-first prosecution
          ledgers.

    These assertions pin the coverage-first rewrite landed in Step 3 (GREEN).
    Helper scriptblocks (GetSectionBody, NormalizeContent)
    are copied verbatim from reporting-economy.Tests.ps1 / specialist-shell-parity
    lines 79-98, per that file's own attribution note. Do not dot-source either
    file — that would run their Describe blocks too.
#>

BeforeDiscovery {
    $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path

    $script:DiscoveryAdversarialReviewPath = Join-Path $RepoRoot 'skills/adversarial-review/SKILL.md'
    $script:DiscoveryCodeCriticPath        = Join-Path $RepoRoot 'agents/Code-Critic.agent.md'
    $script:DiscoveryReviewJudgmentPath    = Join-Path $RepoRoot 'skills/review-judgment/SKILL.md'
}

Describe 'Coverage-first prosecution rewrite (issue #784)' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path

        $script:AdversarialReviewPath = Join-Path $script:RepoRoot 'skills/adversarial-review/SKILL.md'
        $script:CodeCriticPath        = Join-Path $script:RepoRoot 'agents/Code-Critic.agent.md'
        $script:ReviewJudgmentPath    = Join-Path $script:RepoRoot 'skills/review-judgment/SKILL.md'

        # ---------------------------------------------------------------------------
        # Helpers — copied verbatim from reporting-economy.Tests.ps1 (itself copied
        # from specialist-shell-parity.Tests.ps1 lines 31-44 and 136). Do NOT
        # dot-source either file — that would run their Describe blocks too.
        # ---------------------------------------------------------------------------

        $script:GetSectionBody = {
            param(
                [string]$Content,
                [string]$Heading
            )

            $pattern = '(?ms)^' + [regex]::Escape($Heading) + '\s*\r?\n(?<body>.*?)(?=^## |^### |\z)'
            $match = [regex]::Match($Content, $pattern)
            if (-not $match.Success) {
                return ''
            }

            return $match.Groups['body'].Value
        }

        $script:NormalizeContent = {
            param([string]$Content)

            return ($Content -replace "`r`n?", "`n").Trim()
        }

        # ---------------------------------------------------------------------------
        # Canonical fixtures — single source of truth for pinned literals.
        # ---------------------------------------------------------------------------

        # (a) The exact sentence being removed from SKILL.md §2.
        $script:RemovedDowngradeOrOmitSentence = 'If the failure mode cannot be stated clearly, downgrade the item or omit it.'

        # (a) The distinct gotcha-row phrase that must NOT false-positive against (a)'s regex.
        $script:UnrelatedGotchaPhrase = 'downgrade the item before output'
    }

    Context 'Assertion (a): downgrade-or-omit sentence removed from SKILL.md §2' {

        It 'does not contain the exact removed sentence in skills/adversarial-review/SKILL.md' {
            $content = Get-Content -Path $script:AdversarialReviewPath -Raw -ErrorAction Stop

            $content.Contains($script:RemovedDowngradeOrOmitSentence) | Should -BeFalse -Because (
                "Step 3 (GREEN) must remove the sentence '$($script:RemovedDowngradeOrOmitSentence)' " +
                "from skills/adversarial-review/SKILL.md as part of the coverage-first rewrite of " +
                "'### 2. Apply Evidence Standards'. This sentence currently exists at (historically) line 79."
            )
        }

        It 'still retains the unrelated gotcha-row phrase, confirming the regex does not false-positive' {
            # Sanity check on the fixture itself: the distinct phrase at ~line 348
            # ("downgrade the item before output") is legitimate content that must
            # survive the Step 3 rewrite and must never be matched by assertion (a).
            $content = Get-Content -Path $script:AdversarialReviewPath -Raw -ErrorAction Stop

            $content.Contains($script:UnrelatedGotchaPhrase) | Should -BeTrue -Because (
                "The gotcha-row phrase '$($script:UnrelatedGotchaPhrase)' is legitimate content " +
                "unrelated to the removed sentence in assertion (a); it must remain present and " +
                "this test's fixtures must never conflate the two phrases."
            )
        }
    }

    Context 'Assertion (b): SKILL.md §2 tagging + omission-scope prose (Step 3 target literals)' {

        It 'contains an omission scope tied to no-statable-failure-mode and pure-noise in ## 2. Apply Evidence Standards' {
            $content     = Get-Content -Path $script:AdversarialReviewPath -Raw -ErrorAction Stop
            $sectionBody = & $script:GetSectionBody -Content $content -Heading '### 2. Apply Evidence Standards'

            $sectionBody | Should -Not -BeNullOrEmpty -Because (
                "skills/adversarial-review/SKILL.md must have a '### 2. Apply Evidence Standards' " +
                "section for the coverage-first omission-scope language to live in"
            )

            $sectionBody.Contains('omit') | Should -BeTrue -Because (
                "Step 3 must introduce the literal 'omit' scoped to a narrow no-statable-failure-mode " +
                "condition in '### 2. Apply Evidence Standards' of skills/adversarial-review/SKILL.md"
            )

            $sectionBody.Contains('no statable failure mode') | Should -BeTrue -Because (
                "Step 3 must introduce the exact phrase 'no statable failure mode' in " +
                "'### 2. Apply Evidence Standards' of skills/adversarial-review/SKILL.md, scoping " +
                "omission to only that narrow condition"
            )

            $sectionBody.Contains('pure noise') | Should -BeTrue -Because (
                "Step 3 must introduce the exact phrase 'pure noise' co-located with the omission " +
                "scope in '### 2. Apply Evidence Standards' of skills/adversarial-review/SKILL.md"
            )
        }

        It 'contains a requirement that findings are tagged with confidence and severity' {
            $content     = Get-Content -Path $script:AdversarialReviewPath -Raw -ErrorAction Stop
            $sectionBody = & $script:GetSectionBody -Content $content -Heading '### 2. Apply Evidence Standards'

            $sectionBody | Should -Not -BeNullOrEmpty -Because (
                "skills/adversarial-review/SKILL.md must have a '### 2. Apply Evidence Standards' " +
                "section for the coverage-first tagging requirement to live in"
            )

            $sectionBody.Contains('tagged') | Should -BeTrue -Because (
                "Step 3 must introduce the literal 'tagged' in '### 2. Apply Evidence Standards' of " +
                "skills/adversarial-review/SKILL.md, requiring every finding be tagged with an " +
                "explicit confidence + severity"
            )
        }
    }

    Context 'Assertion (c): SKILL.md §4 coverage-vs-economy orthogonality (Step 3 target literal)' {

        It 'states coverage and economy are orthogonal in ## 4. Emit a Usable Ledger' {
            $content     = Get-Content -Path $script:AdversarialReviewPath -Raw -ErrorAction Stop
            $sectionBody = & $script:GetSectionBody -Content $content -Heading '### 4. Emit a Usable Ledger'

            $sectionBody | Should -Not -BeNullOrEmpty -Because (
                "skills/adversarial-review/SKILL.md must have a '### 4. Emit a Usable Ledger' " +
                "section for the coverage-vs-economy split to live in"
            )

            $sectionBody.Contains('orthogonal') | Should -BeTrue -Because (
                "Step 3 must introduce the literal 'orthogonal' in '### 4. Emit a Usable Ledger' of " +
                "skills/adversarial-review/SKILL.md, stating that coverage and economy are orthogonal"
            )

            $sectionBody.Contains('economy') | Should -BeTrue -Because (
                "Step 3's orthogonality statement in '### 4. Emit a Usable Ledger' must name 'economy' " +
                "as one of the two orthogonal axes"
            )

            $sectionBody.Contains('coverage') | Should -BeTrue -Because (
                "Step 3's orthogonality statement in '### 4. Emit a Usable Ledger' must name 'coverage' " +
                "as one of the two orthogonal axes"
            )
        }
    }

    Context 'Assertion (d): Code-Critic.agent.md coverage-first Core Principles bullet' {

        It 'contains coverage-first language in ## Core Principles (position not asserted)' {
            $content     = Get-Content -Path $script:CodeCriticPath -Raw -ErrorAction Stop
            $sectionBody = & $script:GetSectionBody -Content $content -Heading '## Core Principles'

            $sectionBody | Should -Not -BeNullOrEmpty -Because (
                "agents/Code-Critic.agent.md must have a ## Core Principles section for the " +
                "coverage-first bullet to live in"
            )

            $sectionBody.Contains('coverage-first') | Should -BeTrue -Because (
                "Step 3 must add a coverage-first Core Principles bullet to " +
                "agents/Code-Critic.agent.md containing the literal 'coverage-first'. This test " +
                "intentionally does not assert bullet position relative to the reporting-economy " +
                "bullet — that structural invariant is already protected by " +
                "reporting-economy.Tests.ps1."
            )
        }
    }

    Context 'Assertion (e): review-judgment SKILL.md names judge as filter of record' {

        It 'contains the phrase "filter of record" for coverage-first prosecution ledgers' {
            $content     = Get-Content -Path $script:ReviewJudgmentPath -Raw -ErrorAction Stop
            $sectionBody = & $script:GetSectionBody -Content $content -Heading '## Purpose'

            $sectionBody | Should -Not -BeNullOrEmpty -Because (
                "skills/review-judgment/SKILL.md must have a '## Purpose' section for the " +
                "filter-of-record language to live in"
            )

            $sectionBody.Contains('filter of record') | Should -BeTrue -Because (
                "Step 3 must introduce the exact phrase 'filter of record' in the '## Purpose' " +
                "section of skills/review-judgment/SKILL.md, naming the judge as filter of record " +
                "for coverage-first prosecution ledgers"
            )
        }
    }
}
