#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    Contract tests for same-comment review completion emission.

.DESCRIPTION
    Locks issue #379 Step 7 / D3: the review completion marker and the
    judge-rulings block must travel in the same PR comment payload.
    The fixtures are deterministic and repo-local.
#>

Describe 'orchestra-review marker emission contract' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:CodeReviewResponseShellPath = Join-Path $script:RepoRoot 'agents\code-review-response.md'
        $script:CodeReviewResponseBodyPath = Join-Path $script:RepoRoot 'agents\Code-Review-Response.agent.md'
        $script:ReviewJudgmentSkillPath = Join-Path $script:RepoRoot 'skills\review-judgment\SKILL.md'
        $script:CompletionMarkerPattern = '<!--\s*code-review-complete-\d+\s*-->'
        $script:JudgeRulingsPattern = '(?s)<!--\s*judge-rulings\s*\r?\n.*?\r?\n-->'
        $script:SamePayloadPattern = '(?s)<!--\s*code-review-complete-\d+\s*-->.*<!--\s*judge-rulings\s*\r?\n.*?\r?\n-->'
        $script:CodeReviewResponseShell = Get-Content -Path $script:CodeReviewResponseShellPath -Raw
        $script:CodeReviewResponseBody = Get-Content -Path $script:CodeReviewResponseBodyPath -Raw
        $script:ReviewJudgmentSkill = Get-Content -Path $script:ReviewJudgmentSkillPath -Raw

        $script:ContainsMarkerAndRulings = {
            param([string]$Payload)

            return ($Payload -match $script:CompletionMarkerPattern) -and ($Payload -match $script:JudgeRulingsPattern)
        }

        $script:ValidSingleCommentPayload = @'
### Adversarial Review Score Summary

| Finding | Pass | Prosecution (severity, pts) | Defense verdict | Ruling | Confidence | Points |
| ------- | ---- | --------------------------- | --------------- | ------ | ---------- | ------ |
| F1: Missing handshake guard | 1 | high (10 pts) | conceded | ✅ Sustained | high | P+10 |

<!-- code-review-complete-379 -->
<!-- judge-rulings
- id: F1
  judge_ruling: sustained
  judge_confidence: high
  points_awarded: P+10
-->
'@

        $script:SplitCommentPayloads = @(
            @'
### Adversarial Review Score Summary

<!-- code-review-complete-379 -->
'@,
            @'
<!-- judge-rulings
- id: F1
  judge_ruling: sustained
  judge_confidence: high
  points_awarded: P+10
-->
'@
        )

        $script:InvalidMarkerPayload = @'
### Adversarial Review Score Summary

<!-- code-review-complete-pr-379 -->
<!-- judge-rulings
- id: F1
  judge_ruling: sustained
  judge_confidence: high
  points_awarded: P+10
-->
'@
    }

    It 'accepts a single comment payload only when the completion marker and judge-rulings block coexist' {
        (& $script:ContainsMarkerAndRulings -Payload $script:ValidSingleCommentPayload) | Should -BeTrue
        $script:ValidSingleCommentPayload | Should -Match $script:SamePayloadPattern -Because 'the review completion marker and judge-rulings block must travel in the same comment payload'
    }

    It 'rejects split comment fixtures where the marker and judge-rulings block are separated' {
        foreach ($payload in $script:SplitCommentPayloads) {
            (& $script:ContainsMarkerAndRulings -Payload $payload) | Should -BeFalse
        }
    }

    It 'requires the exact code-review-complete-{PR} marker shape' {
        $script:ValidSingleCommentPayload | Should -Match $script:CompletionMarkerPattern
        (& $script:ContainsMarkerAndRulings -Payload $script:InvalidMarkerPayload) | Should -BeFalse -Because 'the PR marker must be numeric and must not add extra marker text'
    }

    It 'requires the Claude judge shell to document the same-payload marker contract' {
        $script:CodeReviewResponseShell | Should -Match 'code-review-complete-\{PR\}' -Because 'the Claude judge shell must name the completion marker explicitly'
        $script:CodeReviewResponseShell | Should -Match 'Return the Markdown score summary, `<!-- code-review-complete-\{PR\} -->` completion marker, and the `judge-rulings` block together in the same response payload\.' -Because 'the Claude judge shell must keep the marker and rulings in one response payload'
        $script:CodeReviewResponseShell | Should -Match 'keep the score summary, `<!-- code-review-complete-\{PR\} -->`, and `judge-rulings` block in the same PR comment payload rather than splitting them across separate comments\.' -Because 'GitHub-backed judge output must keep the marker and rulings together in one comment'
    }

    It 'requires the shared judge contract to keep completion and rulings in the same payload' {
        $script:ReviewJudgmentSkill | Should -Match 'code-review-complete-\{PR\}' -Because 'the shared review-judgment skill must name the completion marker explicitly'
        $script:ReviewJudgmentSkill | Should -Match 'Keep the Markdown score summary, the `<!-- code-review-complete-\{PR\} -->` marker, and the `judge-rulings` block together in the same response payload\.' -Because 'the shared skill must require the same-payload artifact contract'
        $script:ReviewJudgmentSkill | Should -Match 'keep them in the same PR comment rather than splitting them across separate comments\.' -Because 'the shared skill must carry the same-comment GitHub persistence contract'
        $script:CodeReviewResponseBody | Should -Match 'Load `skills/review-judgment/SKILL.md`.*`judge-rulings` output block' -Because 'the shared judge body must continue delegating output-shape ownership to the shared skill'
    }
}
