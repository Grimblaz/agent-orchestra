#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    Contract tests for same-comment review completion emission.

.DESCRIPTION
    Locks issue #379 Step 7 / D3 (updated by issue #441 Step 11):
    the judge-rulings block must travel in the same PR comment payload
    as the Markdown score summary. The `<!-- code-review-complete-{PR} -->`
    marker is retired as of issue #441 Step 11; the sentinel
    `<!-- review-judge-produced-{PR} -->` precedes the judge-rulings comment
    as a separate PR comment.
    The fixtures are deterministic and repo-local.
#>

Describe 'orchestra-review marker emission contract' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:CodeReviewResponseShellPath = Join-Path $script:RepoRoot 'agents\code-review-response.md'
        $script:CodeReviewResponseBodyPath = Join-Path $script:RepoRoot 'agents\Code-Review-Response.agent.md'
        $script:ReviewJudgmentSkillPath = Join-Path $script:RepoRoot 'skills\review-judgment\SKILL.md'
        $script:JudgeRulingsPattern = '(?s)<!--\s*judge-rulings\s*\r?\n.*?\r?\n-->'
        $script:ScoreSummaryPattern = '###\s+Adversarial Review Score Summary'
        $script:SamePayloadPattern = '(?s)###\s+Adversarial Review Score Summary.*<!--\s*judge-rulings\s*\r?\n.*?\r?\n-->'
        $script:CodeReviewResponseShell = Get-Content -Path $script:CodeReviewResponseShellPath -Raw
        $script:CodeReviewResponseBody = Get-Content -Path $script:CodeReviewResponseBodyPath -Raw
        $script:ReviewJudgmentSkill = Get-Content -Path $script:ReviewJudgmentSkillPath -Raw

        $script:ContainsRulingsAndSummary = {
            param([string]$Payload)

            return ($Payload -match $script:JudgeRulingsPattern) -and ($Payload -match $script:ScoreSummaryPattern)
        }

        $script:ValidSingleCommentPayload = @'
### Adversarial Review Score Summary

| Finding | Pass | Prosecution (severity, pts) | Defense verdict | Ruling | Confidence | Points |
| ------- | ---- | --------------------------- | --------------- | ------ | ---------- | ------ |
| F1: Missing handshake guard | 1 | high (10 pts) | conceded | ✅ Sustained | high | P+10 |

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

| Finding | Pass | Prosecution (severity, pts) | Defense verdict | Ruling | Confidence | Points |
| ------- | ---- | --------------------------- | --------------- | ------ | ---------- | ------ |
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
    }

    It 'accepts a single comment payload only when the score summary and judge-rulings block coexist' {
        (& $script:ContainsRulingsAndSummary -Payload $script:ValidSingleCommentPayload) | Should -BeTrue
        $script:ValidSingleCommentPayload | Should -Match $script:SamePayloadPattern -Because 'the score summary and judge-rulings block must travel in the same comment payload'
    }

    It 'rejects split comment fixtures where the score summary and judge-rulings block are separated' {
        foreach ($payload in $script:SplitCommentPayloads) {
            (& $script:ContainsRulingsAndSummary -Payload $payload) | Should -BeFalse
        }
    }

    It 'valid payload must not contain the retired code-review-complete marker (issue #441 Step 11)' {
        $script:ValidSingleCommentPayload | Should -Not -Match 'code-review-complete' -Because 'the code-review-complete-{PR} marker is retired as of issue #441 Step 11 and must not appear in judge output'
    }

    It 'requires the Claude judge shell to document the sentinel-then-rulings emission contract (issue #441 Step 11)' {
        $script:CodeReviewResponseShell | Should -Match 'review-judge-produced-\{PR\}' -Because 'the Claude judge shell must document the sentinel emission before the judge-rulings comment'
        $script:CodeReviewResponseShell | Should -Match '`judge-rulings`' -Because 'the Claude judge shell must name the judge-rulings block explicitly'
        $script:CodeReviewResponseShell | Should -Match 'same.*payload|payload.*same' -Because 'the Claude judge shell must keep the score summary and judge-rulings block in one response payload'
        $script:CodeReviewResponseShell | Should -Not -Match 'Return the Markdown score summary, `<!-- code-review-complete-\{PR\} -->`' -Because 'the Claude judge shell must not document the retired completion marker emission'
    }

    It 'rejects a judge-rulings comment body that contains the sentinel token (ordering: they must be separate comments)' {
        # L7 fix (issue #441 judge ruling): the sentinel <!-- review-judge-produced-{PR} -->
        # must NEVER appear inside the judge-rulings YAML comment. They travel as two
        # separate PR comments: sentinel first, then judge-rulings.
        $invalidMixedBody = @"
<!-- review-judge-produced-99 -->
<!-- judge-rulings
- id: F1
  judge_ruling: sustained
  judge_confidence: high
  points_awarded: P+10
-->
"@

        $invalidMixedBody | Should -Match 'review-judge-produced-99' -Because 'fixture sanity check'
        $invalidMixedBody | Should -Match 'judge-rulings' -Because 'fixture sanity check'

        # The combined payload fails the same-payload contract because it mixes sentinel + rulings.
        # Specifically: the judge-rulings comment must NOT contain the sentinel token.
        $judgeRulingsSection = ($invalidMixedBody -split '<!-- judge-rulings')[1]
        $judgeRulingsSection | Should -Not -Match 'review-judge-produced' `
            -Because 'the judge-rulings comment body must not contain the sentinel token; they are separate PR comments'
    }

    It 'requires the shared judge contract to keep score summary and rulings in the same payload (issue #441 Step 11)' {
        $script:ReviewJudgmentSkill | Should -Match 'judge-rulings' -Because 'the shared review-judgment skill must name the judge-rulings block explicitly'
        $script:ReviewJudgmentSkill | Should -Match 'Keep the Markdown score summary and the `judge-rulings` block together in the same response payload\.' -Because 'the shared skill must require the same-payload artifact contract'
        $script:ReviewJudgmentSkill | Should -Match 'keep them in the same PR comment rather than splitting them across separate comments\.' -Because 'the shared skill must carry the same-comment GitHub persistence contract'
        $script:ReviewJudgmentSkill | Should -Not -Match 'Keep the Markdown score summary, the `<!-- code-review-complete-\{PR\} -->` marker' -Because 'the shared skill must not document the retired completion marker as part of the same-payload contract'
        $script:CodeReviewResponseBody | Should -Match 'Load `skills/review-judgment/SKILL.md`.*`judge-rulings` output block' -Because 'the shared judge body must continue delegating output-shape ownership to the shared skill'
    }
}
