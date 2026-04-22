#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    Contract tests for Claude/Copilot judge-rulings ledger compatibility.

.DESCRIPTION
    Locks issue #379 Step 7 by verifying that the judge-rulings schema in
    skills/review-judgment/SKILL.md stays compatible with deterministic
    synthetic artifacts emitted from Claude and Copilot review flows.
#>

Describe 'orchestra-review ledger schema compatibility contract' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:ReviewJudgmentSkillPath = Join-Path $script:RepoRoot 'skills\review-judgment\SKILL.md'
        $script:ReviewJudgmentSkill = Get-Content -Path $script:ReviewJudgmentSkillPath -Raw
        $script:ExpectedKeys = @('id', 'judge_ruling', 'judge_confidence', 'points_awarded')

        $script:ConvertFromJudgeRulingsPayload = {
            param([string]$Payload)

            $blockMatch = [regex]::Match($Payload, '(?ms)<!--\s*judge-rulings\s*\r?\n(?<body>.*?)\r?\n-->')
            if (-not $blockMatch.Success) {
                throw 'judge-rulings block missing.'
            }

            $rows = @()
            $current = $null
            foreach ($rawLine in ($blockMatch.Groups['body'].Value -split "`r?`n")) {
                $line = $rawLine.Trim()
                if ([string]::IsNullOrWhiteSpace($line)) {
                    continue
                }

                if ($line -match '^-\s+(?<key>[a-z_]+):\s+(?<value>.+?)\s*$') {
                    if ($null -ne $current) {
                        $rows += [pscustomobject]$current
                    }

                    $current = [ordered]@{}
                    $current[$matches['key']] = $matches['value']
                    continue
                }

                if ($line -match '^(?<key>[a-z_]+):\s+(?<value>.+?)\s*$') {
                    if ($null -eq $current) {
                        throw "Encountered judge-rulings field before row start: $line"
                    }

                    $current[$matches['key']] = $matches['value']
                    continue
                }

                throw "Unrecognized judge-rulings line: $line"
            }

            if ($null -ne $current) {
                $rows += [pscustomobject]$current
            }

            return @($rows)
        }

        $script:ClaudeArtifact = @'
### Adversarial Review Score Summary

| Finding | Pass | Prosecution (severity, pts) | Defense verdict | Ruling | Confidence | Points |
| ------- | ---- | --------------------------- | --------------- | ------ | ---------- | ------ |
| F1: Lite mode marker drift | — | medium (5 pts) | disproved | ❌ Defense sustained | medium | D+5 |
| F2: Missing same-comment emission | — | high (10 pts) | conceded | ✅ Sustained | high | P+10 |

<!-- judge-rulings
- id: F1
  judge_ruling: defense-sustained
  judge_confidence: medium
  points_awarded: D+5
- id: F2
  judge_ruling: sustained
  judge_confidence: high
  points_awarded: P+10
-->
'@

        $script:CopilotArtifact = @'
### Adversarial Review Score Summary

Reviewed against the same prosecution and defense ledger.

<!-- judge-rulings
- id: F1
  judge_ruling: defense-sustained
  judge_confidence: medium
  points_awarded: D+5
- id: F2
  judge_ruling: sustained
  judge_confidence: high
  points_awarded: P+10
-->
'@
    }

    It 'keeps the review-judgment skill example on the canonical four-field schema' {
        $parsed = & $script:ConvertFromJudgeRulingsPayload -Payload $script:ReviewJudgmentSkill

        $parsed.Count | Should -BeGreaterThan 0 -Because 'SKILL.md must carry at least one judge-rulings example row'
        @($parsed[0].PSObject.Properties.Name) | Should -Be $script:ExpectedKeys
    }

    It 'parses the synthetic Claude artifact into the canonical judge-rulings shape' {
        $parsed = & $script:ConvertFromJudgeRulingsPayload -Payload $script:ClaudeArtifact

        $parsed.Count | Should -Be 2
        foreach ($row in $parsed) {
            @($row.PSObject.Properties.Name) | Should -Be $script:ExpectedKeys
        }
    }

    It 'parses synthetic Claude and Copilot artifacts into field-identical ruling structures' {
        $claudeParsed = & $script:ConvertFromJudgeRulingsPayload -Payload $script:ClaudeArtifact
        $copilotParsed = & $script:ConvertFromJudgeRulingsPayload -Payload $script:CopilotArtifact

        ($claudeParsed | ConvertTo-Json -Depth 10) | Should -Be ($copilotParsed | ConvertTo-Json -Depth 10)
    }
}
