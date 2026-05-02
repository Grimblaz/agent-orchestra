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
