#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    Contract tests for /code-conductor and /review-github inline commands.

.DESCRIPTION
    Enforces the command-file contract for Code-Conductor inline invocation paths:
    - /code-conductor: non-hub-mode free-text task routing
    - /review-github: GitHub review intake and proxy prosecution

    Both commands adopt Code-Conductor inline after D1 body resolution
    and must not dispatch Code-Conductor as a parent-side subagent.

    Issue #507 introduced these commands as Claude-native counterparts to
    the hub-mode /orchestrate entry point.
#>

Describe 'Code-Conductor inline commands contract' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:CodeConductorCommandPath = Join-Path $script:RepoRoot 'commands/code-conductor.md'
        $script:ReviewGithubCommandPath = Join-Path $script:RepoRoot 'commands/review-github.md'
        $script:CodeConductorAgentPath = Join-Path $script:RepoRoot 'agents/Code-Conductor.agent.md'

        $script:ExtractFrontmatter = {
            param([string]$Content)
            $match = [regex]::Match($Content, '(?ms)\A---\r?\n(?<fm>.*?)\r?\n---')
            if (-not $match.Success) { return '' }
            return $match.Groups['fm'].Value
        }

        $script:GetFrontmatterField = {
            param([string]$Frontmatter, [string]$FieldName)
            $match = [regex]::Match($Frontmatter, "(?m)^${FieldName}:\s*(?<val>\S+)\s*(#.*)?$")
            if (-not $match.Success) { return $null }
            return $match.Groups['val'].Value.Trim()
        }
    }

    Context '/code-conductor command enforcement' {

        It 'requires frontmatter with description, argument-hint, model, and effort fields' {
            Test-Path $script:CodeConductorCommandPath | Should -BeTrue -Because 'commands/code-conductor.md must exist'

            $content = Get-Content -Path $script:CodeConductorCommandPath -Raw -ErrorAction Stop
            $fm = & $script:ExtractFrontmatter -Content $content

            $fm | Should -Not -BeNullOrEmpty -Because '/code-conductor must have YAML frontmatter'
            $fm | Should -Match 'description:' -Because '/code-conductor frontmatter must declare description'
            $fm | Should -Match 'argument-hint:' -Because '/code-conductor frontmatter must declare argument-hint'

            $model = & $script:GetFrontmatterField -Frontmatter $fm -FieldName 'model'
            $effort = & $script:GetFrontmatterField -Frontmatter $fm -FieldName 'effort'

            $model | Should -Be 'sonnet' -Because '/code-conductor must declare model: sonnet'
            $effort | Should -Be 'high' -Because '/code-conductor must declare effort: high'
        }

        It 'requires non-hub-mode routing and Code-Conductor body reference' {
            $content = Get-Content -Path $script:CodeConductorCommandPath -Raw -ErrorAction Stop

            $content | Should -Match '(?is)non-hub-mode' -Because '/code-conductor must document non-hub-mode behavior'
            $content | Should -Match '(?is)agents/Code-Conductor\.agent\.md' -Because '/code-conductor must reference the Code-Conductor shared body'
            $content | Should -Match '(?is)ARGUMENTS:\s*\$ARGUMENTS' -Because '/code-conductor must pass $ARGUMENTS to the body'
        }

        It 'forbids subagent_type: code-conductor and Review mode selector' {
            $content = Get-Content -Path $script:CodeConductorCommandPath -Raw -ErrorAction Stop

            $content | Should -Not -Match '(?is)subagent_type:\s*code-conductor' -Because '/code-conductor must not dispatch Code-Conductor as a parent-side subagent'
            $content | Should -Not -Match '(?is)Review mode selector:' -Because '/code-conductor must not contain Review mode selector language'
        }
    }

    Context '/review-github command enforcement' {

        It 'requires frontmatter with description mentioning GitHub review intake' {
            Test-Path $script:ReviewGithubCommandPath | Should -BeTrue -Because 'commands/review-github.md must exist'

            $content = Get-Content -Path $script:ReviewGithubCommandPath -Raw -ErrorAction Stop
            $fm = & $script:ExtractFrontmatter -Content $content

            $fm | Should -Not -BeNullOrEmpty -Because '/review-github must have YAML frontmatter'
            $fm | Should -Match '(?is)description:.*GitHub review intake' -Because '/review-github frontmatter must mention GitHub review intake'
            $fm | Should -Match '(?is)description:.*proxy prosecution' -Because '/review-github frontmatter must mention proxy prosecution'

            $model = & $script:GetFrontmatterField -Frontmatter $fm -FieldName 'model'
            $effort = & $script:GetFrontmatterField -Frontmatter $fm -FieldName 'effort'

            $model | Should -Be 'sonnet' -Because '/review-github must declare model: sonnet'
            $effort | Should -Be 'high' -Because '/review-github must declare effort: high'
        }

        It 'requires GitHub review intake routing literals' {
            $content = Get-Content -Path $script:ReviewGithubCommandPath -Raw -ErrorAction Stop

            $content | Should -Match '(?is)review github' -Because '/review-github must contain "review github" routing literal'
            $content | Should -Match '(?is)skills/code-review-intake/SKILL\.md' -Because '/review-github must reference code-review-intake skill'
            $content | Should -Match '(?is)gh pr view' -Because '/review-github must use gh pr view to resolve PR context'
            $content | Should -Match '(?is)AskUserQuestion' -Because '/review-github must use AskUserQuestion for missing PR number'
            $content | Should -Match '(?is)\$PR_NUMBER' -Because '/review-github must reference $PR_NUMBER variable'
            $content | Should -Match '(?is)ARGUMENTS:\s*\$ARGUMENTS' -Because '/review-github must pass $ARGUMENTS to the body'
        }

        It 'documents all three AskUserQuestion fallback conditions' {
            $content = Get-Content -Path $script:ReviewGithubCommandPath -Raw -ErrorAction Stop

            $content | Should -Match '(?is)no PR for the current branch' -Because '/review-github must document the no-PR fallback condition'
            $content | Should -Match '(?is)detached HEAD' -Because '/review-github must document the detached-HEAD fallback condition'
            $content | Should -Match '(?is)fork branch has no upstream PR' -Because '/review-github must document the fork-without-upstream-PR fallback condition'
        }

        It 'forbids subagent_type: code-conductor and Review mode selector' {
            $content = Get-Content -Path $script:ReviewGithubCommandPath -Raw -ErrorAction Stop

            $content | Should -Not -Match '(?is)subagent_type:\s*code-conductor' -Because '/review-github must not dispatch Code-Conductor as a parent-side subagent'
            $content | Should -Not -Match '(?is)Review mode selector:' -Because '/review-github must not contain Review mode selector language'
        }

        It 'carries the s3 Post-judgment disposition gate pointer block and still contains no Review mode selector literal (issue #869 s5)' {
            # Part 2 of the s5 test slice: s3 rewrote the old "Review mode
            # selector" block into a pointer at
            # skills/code-review-intake/references/response-loop-completion.md's
            # Post-Judge Disposition Gate step -- this is a contract
            # assertion that the rewrite landed and stayed landed, not a
            # regression test for a defect.
            $content = Get-Content -Path $script:ReviewGithubCommandPath -Raw -ErrorAction Stop

            $content | Should -Match '(?is)Post-judgment disposition gate' -Because '/review-github must carry the s3 Post-judgment disposition gate pointer block'
            $content | Should -Not -Match '(?is)Review mode selector:' -Because '/review-github must still contain no Review mode selector literal after the s3 rewrite'
        }
    }

    Context 'Code-Conductor.agent.md GitHub review sentence preservation' {

        It 'preserves the byte-equal GitHub-triggered review sentence' {
            Test-Path $script:CodeConductorAgentPath | Should -BeTrue -Because 'agents/Code-Conductor.agent.md must exist'

            $content = Get-Content -Path $script:CodeConductorAgentPath -Raw -ErrorAction Stop

            $expectedSentence = 'GitHub-triggered review requests (`github review`, `review github`, `cr review`) still enter through the GitHub intake path described in the loaded references before the generic local review loop runs.'

            $content | Should -Match ([regex]::Escape($expectedSentence)) -Because 'Code-Conductor.agent.md must preserve the byte-equal GitHub-triggered review sentence'
        }

        It 'preserves the byte-equal additive /review-github sentence' {
            $content = Get-Content -Path $script:CodeConductorAgentPath -Raw -ErrorAction Stop

            $expectedSlashSentence = 'On Claude Code, the deterministic slash-command equivalent of these prose triggers is /review-github (see commands/review-github.md).'
            $content | Should -Match ([regex]::Escape($expectedSlashSentence)) -Because 'Code-Conductor.agent.md must preserve the byte-equal /review-github additive sentence in the Review Reconciliation Loop section'
        }
    }

    Context 'Code-Conductor.agent.md routing placement (issue #507 F1 regression)' {

        It 'declares the Non-hub-mode invocation subsection' {
            Test-Path $script:CodeConductorAgentPath | Should -BeTrue -Because 'agents/Code-Conductor.agent.md must exist'

            $content = Get-Content -Path $script:CodeConductorAgentPath -Raw -ErrorAction Stop

            $content | Should -Match '(?m)^####\s+Non-hub-mode invocation \(slash-command path\)\s*$' -Because 'Code-Conductor.agent.md must declare the Non-hub-mode invocation subsection'
        }

        It 'includes /code-conductor in the primary skip-hub-mode sentence' {
            $content = Get-Content -Path $script:CodeConductorAgentPath -Raw -ErrorAction Stop

            # Extract the main sentence (before "Exception:") that lists slash commands skipping hub mode
            $skipHubSentencePattern = '(?s)Skip hub mode entirely when the user invokes a specific slash command.*?(?=Exception:|####|\z)'
            $match = [regex]::Match($content, $skipHubSentencePattern)

            $match.Success | Should -BeTrue -Because 'Code-Conductor.agent.md must contain the skip-hub-mode sentence'
            $match.Value | Should -Match '/code-conductor' -Because 'The skip-hub-mode sentence must include /code-conductor in the examples list'
        }

        It 'Non-hub-mode subsection routes review tokens correctly (longest-phrase-first; binding-anchored)' {
            $content = Get-Content -Path $script:CodeConductorAgentPath -Raw -ErrorAction Stop

            # Verify the Non-hub-mode subsection documents both routing branches
            $subSectionPattern = '(?s)#### Non-hub-mode invocation \(slash-command path\).*?(?=\r?\n###|\r?\n##|\z)'
            $match = [regex]::Match($content, $subSectionPattern)

            $match.Success | Should -BeTrue -Because 'Code-Conductor.agent.md must contain the Non-hub-mode invocation subsection'

            # Binding-anchored assertions: each trigger phrase must co-occur with its target in the same routing clause,
            # so a drift edit that swaps trigger->target pairings cannot pass independent substring checks.
            $match.Value | Should -Match '(?is)`github review`[^.]*GitHub intake|`review github`[^.]*GitHub intake|`cr review`[^.]*GitHub intake' -Because 'The Non-hub-mode subsection must bind a GitHub-trigger phrase to the GitHub intake path'
            $match.Value | Should -Match '(?is)bare\s+`review`[^.]*Review Reconciliation Loop' -Because 'The Non-hub-mode subsection must bind bare `review` to the Review Reconciliation Loop'
            $match.Value | Should -Match '(?is)longest-phrase-first' -Because 'The Non-hub-mode subsection must specify literal longest-phrase-first match order'

            # Canonical-trigger parity: all three line-338 GitHub-trigger phrases must appear in the routing prose
            # (mirrors the byte-equal preservation of line 338).
            $match.Value | Should -Match '(?is)github review' -Because 'The Non-hub-mode subsection must enumerate the canonical `github review` trigger'
            $match.Value | Should -Match '(?is)review github' -Because 'The Non-hub-mode subsection must enumerate the canonical `review github` trigger'
            $match.Value | Should -Match '(?is)cr review' -Because 'The Non-hub-mode subsection must enumerate the canonical `cr review` trigger'
        }

        It 'excludes /code-conductor from the /orchestrate exception clause' {
            $content = Get-Content -Path $script:CodeConductorAgentPath -Raw -ErrorAction Stop

            # Find the paragraph containing "Skip hub mode entirely" through the next heading
            $paragraphPattern = '(?s)Skip hub mode entirely.*?(?=\r?\n\r?\n####|\r?\n####)'
            $match = [regex]::Match($content, $paragraphPattern)

            $match.Success | Should -BeTrue -Because 'Code-Conductor.agent.md must contain the skip-hub-mode paragraph'

            # Split on "Exception:" to isolate the exception clause (which re-enables hub mode for /orchestrate)
            $sentenceAndException = $match.Value -split 'Exception:', 2

            $sentenceAndException.Count | Should -BeGreaterThan 1 -Because 'The paragraph must contain an Exception clause'

            # Verify /code-conductor does NOT appear in the exception clause (it should skip hub mode, not re-enable it)
            $exceptionClause = $sentenceAndException[1]
            $exceptionClause | Should -Not -Match '/code-conductor' -Because '/code-conductor must remain in skip-hub-mode list, not the hub-mode exception'
        }
    }

    Context 'response-loop-completion.md wording-lock contract (issue #869 s5, Part 3)' {
        # Pinned-literal wording-lock on s1's rewrite of the Post-Judge
        # Disposition Gate's loud-failure literals and per-judge-pass firing
        # language. This is a FUTURE-regression guard: the exact erosion
        # class that caused the original 15% landing rate (issue #869) was a
        # quiet wording drift away from these loud literals -- this test
        # exists so an accidental reversion fails CI instead of silently
        # landing again.

        BeforeAll {
            $script:ResponseLoopCompletionPath = Join-Path $script:RepoRoot 'skills/code-review-intake/references/response-loop-completion.md'
        }

        It 'preserves both loud not-posted literals verbatim' {
            Test-Path $script:ResponseLoopCompletionPath | Should -BeTrue -Because 'skills/code-review-intake/references/response-loop-completion.md must exist'

            $content = Get-Content -Path $script:ResponseLoopCompletionPath -Raw -ErrorAction Stop

            $content | Should -Match ([regex]::Escape('review-dispositions-{PR} not posted')) -Because 'response-loop-completion.md must preserve the review-dispositions loud literal verbatim'
            $content | Should -Match ([regex]::Escape('engagement-record-review-{PR} not posted')) -Because 'response-loop-completion.md must preserve the engagement-record-review loud literal verbatim'
        }

        It 'preserves the per-judge-pass firing language' {
            $content = Get-Content -Path $script:ResponseLoopCompletionPath -Raw -ErrorAction Stop

            $content | Should -Match '(?is)once per judge pass' -Because 'response-loop-completion.md must document that the Post-Judge Disposition Gate fires once per judge pass (main and post-fix), not once total'
        }

        It 'preserves the zero-sustained-pass emission clause verbatim' {
            $content = Get-Content -Path $script:ResponseLoopCompletionPath -Raw -ErrorAction Stop

            $content | Should -Match ([regex]::Escape('A zero-sustained judge pass still emits both markers below, with `entries: []` on the dispositions marker.')) -Because 'response-loop-completion.md must document that a zero-sustained judge pass still emits both markers with entries: []'
        }

        It 'preserves the R4 fail-closed clause in review-reconciliation.md verbatim' {
            $reviewReconciliationPath = Join-Path $script:RepoRoot 'skills/validation-methodology/references/review-reconciliation.md'
            Test-Path $reviewReconciliationPath | Should -BeTrue -Because 'skills/validation-methodology/references/review-reconciliation.md must exist'

            $content = Get-Content -Path $reviewReconciliationPath -Raw -ErrorAction Stop

            $content | Should -Match ([regex]::Escape('**Fail closed**: if neither the in-session set nor the posted marker is available for a finding, treat its disposition as unresolved and do not dispatch it')) -Because 'review-reconciliation.md Batch Specialist Dispatch (R4) must preserve the fail-closed clause verbatim'
        }
    }
}
