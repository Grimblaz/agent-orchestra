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
        $script:CodeConductorCommandPath = Join-Path $script:RepoRoot 'commands\code-conductor.md'
        $script:ReviewGithubCommandPath = Join-Path $script:RepoRoot 'commands\review-github.md'
        $script:CodeConductorAgentPath = Join-Path $script:RepoRoot 'agents\Code-Conductor.agent.md'

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
            $effort | Should -Be 'medium' -Because '/code-conductor must declare effort: medium'
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
            $effort | Should -Be 'medium' -Because '/review-github must declare effort: medium'
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

        It 'forbids subagent_type: code-conductor and Review mode selector' {
            $content = Get-Content -Path $script:ReviewGithubCommandPath -Raw -ErrorAction Stop

            $content | Should -Not -Match '(?is)subagent_type:\s*code-conductor' -Because '/review-github must not dispatch Code-Conductor as a parent-side subagent'
            $content | Should -Not -Match '(?is)Review mode selector:' -Because '/review-github must not contain Review mode selector language'
        }
    }

    Context 'Code-Conductor.agent.md GitHub review sentence preservation' {

        It 'preserves the byte-equal GitHub-triggered review sentence' {
            Test-Path $script:CodeConductorAgentPath | Should -BeTrue -Because 'agents/Code-Conductor.agent.md must exist'

            $content = Get-Content -Path $script:CodeConductorAgentPath -Raw -ErrorAction Stop

            $expectedSentence = 'GitHub-triggered review requests (`github review`, `review github`, `cr review`) still enter through the GitHub intake path described in the loaded references before the generic local review loop runs.'

            $content | Should -Match ([regex]::Escape($expectedSentence)) -Because 'Code-Conductor.agent.md must preserve the byte-equal GitHub-triggered review sentence'
        }

        It 'contains the additive /review-github sentence' {
            $content = Get-Content -Path $script:CodeConductorAgentPath -Raw -ErrorAction Stop

            $content | Should -Match '(?is)/review-github' -Because 'Code-Conductor.agent.md must mention /review-github command'
        }
    }
}
