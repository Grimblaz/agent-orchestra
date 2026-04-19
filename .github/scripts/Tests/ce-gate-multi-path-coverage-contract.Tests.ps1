#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
.SYNOPSIS
    Contract tests for CE Gate multi-path output coverage wording.

.DESCRIPTION
    Locks the issue #216 CE Gate multi-path coverage contract across:
      - agents/Issue-Planner.agent.md
      - Documents/Design/code-review.md

        The files must describe the same semantics for:
            - a new output block emitted in more than one conditional path triggers CE Gate coverage
            - at least one CE Gate scenario is required for each path where the block appears
            - each scenario's acceptance criterion specifies the expected behavior of every consuming agent in that path, not merely output format
            - coverage explicitly includes a normal path plus an early-exit or insufficient_data style path
            - single-path outputs are out of scope

        These tests intentionally avoid brittle exact-sentence locks and do not cover runtime script behavior or Process-Review routing behavior.
        They are RED coverage for issue #216 until Issue-Planner and the committed code-review design are aligned.
#>

Describe 'ce gate multi-path output coverage contract' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:IssuePlanner = Join-Path $script:RepoRoot 'agents\Issue-Planner.agent.md'
        $script:CodeReviewDesign = Join-Path $script:RepoRoot 'Documents\Design\code-review.md'

        $script:ReadContent = {
            param([string]$Path)

            return Get-Content -Path $Path -Raw
        }

        $script:IssuePlannerRuleAnchorPattern = '(?i)(?=[^\r\n]*CE Gate)(?=[^\r\n]*multi(?:-| )path)(?=[^\r\n]*output)'
        $script:CodeReviewRuleAnchorPattern = '(?i)(?=[^\r\n]*CE Gate)(?=[^\r\n]*plan(?:ning)?)(?=[^\r\n]*output)'
        $script:GetCeGateMultiPathRuleBlock = {
            param(
                [string]$Content,
                [ValidateSet('IssuePlanner', 'CodeReview')]
                [string]$DocumentKind
            )

            $anchorPattern = switch ($DocumentKind) {
                'IssuePlanner' { $script:IssuePlannerRuleAnchorPattern }
                'CodeReview' { $script:CodeReviewRuleAnchorPattern }
            }

            $lines = $Content -split '\r?\n'
            $startIndex = -1

            for ($index = 0; $index -lt $lines.Count; $index++) {
                if ($lines[$index] -match $anchorPattern) {
                    $startIndex = $index
                    break
                }
            }

            if ($startIndex -lt 0) {
                throw "Unable to locate the $DocumentKind CE Gate multi-path rule block."
            }

            $blockLines = @($lines[$startIndex])

            for ($index = $startIndex + 1; $index -lt $lines.Count; $index++) {
                $line = $lines[$index]

                if ([string]::IsNullOrWhiteSpace($line)) {
                    break
                }

                if ($DocumentKind -eq 'IssuePlanner' -and $line -match '^\s*-\s+') {
                    break
                }

                if ($line -match '^\s{0,3}#{2,}\s+') {
                    break
                }

                $blockLines += $line
            }

            return (($blockLines -join "`n").Trim())
        }

        $script:ApplicabilityScopePattern = '(?is)(when|if|whenever)\s+(?<scope>(?:(?:a|any|each|every)\s+script|scripts|(?:the\s+)?`?[A-Za-z0-9._-]+\.ps1`?(?:\s+script)?))\s+(emits|produces)\s+(?:a\s+)?(new output block|output block).{0,220}(more than one|multiple|more than 1).{0,160}(conditional path|conditional paths|paths?)'
        $script:GetApplicabilityScopeSignature = {
            param([string]$Content)

            $normalizedScopes = foreach ($match in [regex]::Matches($Content, $script:ApplicabilityScopePattern)) {
                $normalizedScope = ($match.Groups['scope'].Value -replace '`', '').ToLowerInvariant()

                if ($normalizedScope -match '\.ps1(?:\s+script)?$') {
                    'specific-script:' + ($normalizedScope -replace '\s+script$', '')
                    continue
                }

                if ($normalizedScope -match '\bscript') {
                    'generic-script'
                }
            }

            return (($normalizedScopes | Select-Object -Unique) -join '|')
        }

        $script:MultiPathOutputTriggerPattern = '(?is)(new output block|output block).{0,220}(more than one|multiple|more than 1).{0,160}(conditional path|conditional paths|paths?)'
        $script:PerPathScenarioPattern = '(?is)((at least one|one or more).{0,160}(CE Gate )?scenario.{0,180}(each|per|every).{0,120}(path|conditional path))|(((each|per|every).{0,120}(path|conditional path)).{0,220}(at least one|one or more).{0,160}(CE Gate )?scenario)'
        $script:ConsumingAgentBehaviorPattern = '(?is)(acceptance criterion|acceptance criteria|criterion).{0,260}(expected behavior|behavior).{0,220}(every|each|all).{0,120}(consuming agent|consuming agents|consumer|consumers|downstream agent|downstream agents).{0,220}(that path|per path|in that path|in the path)'
        $script:NotFormatOnlyPattern = '(?is)(acceptance criterion|acceptance criteria|criterion).{0,260}(not merely|not just|not only|rather than only).{0,140}(output format|format alone|output shape|shape alone)'
        $script:NormalAndEarlyExitCoveragePattern = '(?is)((normal(?:-| )path|standard(?:-| )path|full(?:-| )path|successful(?:-| )path).{0,320}(early(?:-| )exit|insufficient_data|insufficient data|short-circuit))|((early(?:-| )exit|insufficient_data|insufficient data|short-circuit).{0,320}(normal(?:-| )path|standard(?:-| )path|full(?:-| )path|successful(?:-| )path))'
        $script:SinglePathOutOfScopePattern = '(?is)(single(?:-| )path|single conditional path|only one conditional path|one conditional path).{0,260}(out of scope|non-goal|not in scope|does not apply|not required)'

        $script:SharedContractPatterns = @(
            @{
                Name    = 'multi-path output trigger rule'
                Pattern = $script:MultiPathOutputTriggerPattern
            },
            @{
                Name    = 'per-path CE Gate scenario rule'
                Pattern = $script:PerPathScenarioPattern
            },
            @{
                Name    = 'per-path consuming-agent acceptance criterion rule'
                Pattern = $script:ConsumingAgentBehaviorPattern
            },
            @{
                Name    = 'not-format-only acceptance criterion rule'
                Pattern = $script:NotFormatOnlyPattern
            },
            @{
                Name    = 'normal-path plus early-exit coverage rule'
                Pattern = $script:NormalAndEarlyExitCoveragePattern
            },
            @{
                Name    = 'single-path out-of-scope boundary'
                Pattern = $script:SinglePathOutOfScopePattern
            }
        )
    }

    It 'requires Issue-Planner to describe CE Gate coverage for each conditional output path and downstream consumer behavior' {
        $content = & $script:ReadContent -Path $script:IssuePlanner
        $ruleBlock = & $script:GetCeGateMultiPathRuleBlock -Content $content -DocumentKind 'IssuePlanner'

        $ruleBlock | Should -Match $script:MultiPathOutputTriggerPattern -Because 'Issue-Planner must trigger the CE Gate rule when a new output block appears in more than one conditional path'
        $ruleBlock | Should -Match $script:PerPathScenarioPattern -Because 'Issue-Planner must require at least one CE Gate scenario for each path where the new output block appears'
        $ruleBlock | Should -Match $script:ConsumingAgentBehaviorPattern -Because 'Issue-Planner must require each scenario to state the expected behavior of every consuming agent in that path'
        $ruleBlock | Should -Match $script:NotFormatOnlyPattern -Because 'Issue-Planner must make output-format-only acceptance criteria insufficient for these CE Gate scenarios'
        $ruleBlock | Should -Match $script:NormalAndEarlyExitCoveragePattern -Because 'Issue-Planner must explicitly cover both a normal path and an early-exit or insufficient_data style path'
        $ruleBlock | Should -Match $script:SinglePathOutOfScopePattern -Because 'Issue-Planner must keep single-path outputs out of scope for this CE Gate requirement'
    }

    It 'requires the committed code-review design to stay aligned with the CE Gate multi-path coverage contract' {
        $content = & $script:ReadContent -Path $script:CodeReviewDesign
        $ruleBlock = & $script:GetCeGateMultiPathRuleBlock -Content $content -DocumentKind 'CodeReview'

        foreach ($check in $script:SharedContractPatterns) {
            $ruleBlock | Should -Match $check.Pattern -Because "code-review must include the $($check.Name) wording for the issue #216 CE Gate coverage contract"
        }
    }

    It 'treats a named-script trigger as narrower than the generic any-script trigger' {
        $genericScopeSignature = & $script:GetApplicabilityScopeSignature -Content 'when a script emits a new output block in more than one conditional path, require at least one CE Gate scenario for each path where the block appears.'
        $specificScopeSignature = & $script:GetApplicabilityScopeSignature -Content 'when `aggregate-review-scores.ps1` emits a new output block in more than one conditional path, require at least one CE Gate scenario for each path where the block appears.'

        $genericScopeSignature | Should -Be 'generic-script' -Because 'the contract must recognize the intended any-script applicability scope'
        $specificScopeSignature | Should -Be 'specific-script:aggregate-review-scores.ps1' -Because 'the contract must recognize when wording narrows the trigger to a named script'
        $genericScopeSignature | Should -Not -Be $specificScopeSignature -Because 'a script-specific trigger must not be treated as equivalent to the generic any-script rule'
    }

    It 'derives CE Gate applicability scope from the targeted rule block instead of unrelated examples elsewhere in the file' -TestCases @(
        @{
            DocumentKind = 'IssuePlanner'
            Content      = @'
- Historical example: when `aggregate-review-scores.ps1` emits a new output block in more than one conditional path, a prior review missed the early-exit path.
- **CE Gate multi-path output coverage** — when a script emits a new output block in more than one conditional path, require at least one CE Gate scenario for each path where the block appears. Each scenario's acceptance criterion must specify the expected behavior of every consuming agent in that path, not merely output format. The motivating example is a normal path plus an early-exit or `insufficient_data` path. If the block appears in only one conditional path, this rule is out of scope.
- Another rule unrelated to CE Gate scope.
'@
        }
        @{
            DocumentKind = 'CodeReview'
            Content      = @'
Historical note: when `aggregate-review-scores.ps1` emits a new output block in more than one conditional path, reviewers should inspect both paths.

CE Gate planning note: when a script emits a new output block in more than one conditional path, the plan requires at least one CE Gate scenario for each path where the block appears. Each scenario's acceptance criterion must specify the expected behavior of every consuming agent in that path, not merely output format. The motivating example is the issue #213 `aggregate-review-scores.ps1` to Process-Review normal-path versus early-exit or `insufficient_data` path split. If the block appears in only one conditional path, this rule is out of scope.

### Process-Review Integration
'@
        }
    ) {
        param(
            [string]$DocumentKind,
            [string]$Content
        )

        $ruleBlock = & $script:GetCeGateMultiPathRuleBlock -Content $Content -DocumentKind $DocumentKind
        $scopeSignature = & $script:GetApplicabilityScopeSignature -Content $ruleBlock

        $scopeSignature | Should -Be 'generic-script' -Because 'only the targeted CE Gate multi-path rule block should control applicability scope parity'
        $ruleBlock | Should -Not -Match 'Historical (example|note): when `aggregate-review-scores\.ps1` emits' -Because 'unrelated named-script examples outside the targeted rule block must not contaminate the applicability scope classifier'
    }

    It 'requires Issue-Planner and code-review to keep the CE Gate trigger scope aligned as the same any-script rule' {
        $issuePlannerContent = & $script:ReadContent -Path $script:IssuePlanner
        $codeReviewContent = & $script:ReadContent -Path $script:CodeReviewDesign
        $issuePlannerRuleBlock = & $script:GetCeGateMultiPathRuleBlock -Content $issuePlannerContent -DocumentKind 'IssuePlanner'
        $codeReviewRuleBlock = & $script:GetCeGateMultiPathRuleBlock -Content $codeReviewContent -DocumentKind 'CodeReview'

        $issuePlannerScopeSignature = & $script:GetApplicabilityScopeSignature -Content $issuePlannerRuleBlock
        $codeReviewScopeSignature = & $script:GetApplicabilityScopeSignature -Content $codeReviewRuleBlock

        $issuePlannerScopeSignature | Should -Be 'generic-script' -Because 'Issue-Planner must keep the trigger scoped to any script rather than narrowing it to a specific script'
        $codeReviewScopeSignature | Should -Be 'generic-script' -Because 'code-review must mirror the same any-script trigger scope as Issue-Planner'
        $issuePlannerScopeSignature | Should -Be $codeReviewScopeSignature -Because 'Issue-Planner and code-review must stay in parity on the applicability scope of the CE Gate trigger rule'
    }
}