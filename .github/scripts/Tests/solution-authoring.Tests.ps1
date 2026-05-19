#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#!
.SYNOPSIS
    Contract tests for the solution-authoring skill body and structural assertions.

.DESCRIPTION
    Locks issue #574: the solution-authoring skill body codifies the 7 D-X decisions
    with the correct shape (5 rule + 5 template sections, no provides:, decision-brief
    terminology, forward-compat note preserving teaching_paragraph_excerpt, and
    recommendation-shift token present).
#>

Describe 'solution-authoring SKILL body' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:SkillPath = Join-Path $script:RepoRoot 'skills\solution-authoring\SKILL.md'
        $script:Content = (Get-Content -Path $script:SkillPath -Raw -ErrorAction Stop) -replace "`r`n?", "`n"
    }

    It 'AC11.a — file exists' {
        $script:SkillPath | Should -Exist
    }

    It 'AC11.a — frontmatter present (file starts with YAML front matter block)' {
        $script:Content | Should -Match '(?s)^---\n'
    }

    It 'AC11.a — does not declare provides:' {
        $script:Content | Should -Not -Match '(?m)^provides:'
    }

    It 'AC11.a — body is at or under 200 lines' {
        $lineCount = ($script:Content -split "`n").Count
        $lineCount | Should -BeLessOrEqual 200 -Because 'body must stay under the 200-line cap'
    }

    It 'AC11.a — contains exactly 5 ### Rule: sections' {
        $ruleMatches = [regex]::Matches($script:Content, '(?m)^### Rule:')
        $ruleMatches.Count | Should -Be 5 -Because 'body must have exactly 5 rule sections'
    }

    It 'AC11.a — contains exactly 5 ### Template: sections' {
        $templateMatches = [regex]::Matches($script:Content, '(?m)^### Template:')
        $templateMatches.Count | Should -Be 5 -Because 'body must have exactly 5 template sections'
    }

    It 'AC11.a — each Template section contains an exemplar marker' {
        $templateSections = $script:Content -split '(?m)^### Template:' | Select-Object -Skip 1
        $templateSections.Count | Should -Be 5 -Because 'there must be 5 template sections to check'
        foreach ($section in $templateSections) {
            $section | Should -Match '\*\*Exemplar\*\*' -Because 'each template section must contain an **Exemplar** marker'
        }
    }

    It 'AC11.e — literal **Recommendation shift** token present in body' {
        $script:Content | Should -Match '\*\*Recommendation shift\*\*' -Because 'recommendation-shift template must contain the literal token'
    }

    It 'AC11.e — v0 do-not-apply comment present on same-decision-resume skip rule' {
        $script:Content | Should -Match '<!-- v0: do not apply; see #575 for marker-driven activation -->' -Because 'same-decision-resume must be gated with v0 comment'
    }

    It 'AC11.g — no bare "teaching paragraph" (case-insensitive) outside forward-compat allowlist' {
        # Allowlist: forward-compat glossary line referencing teaching_paragraph_excerpt, and Exemplar blocks.
        # Split by the allowlist anchor and check that "teaching paragraph" does not appear in non-allowlist content.
        $allowlistAnchor = 'teaching_paragraph_excerpt'
        $lines = $script:Content -split "`n"
        $violations = $lines | Where-Object {
            $_ -imatch 'teaching paragraph' -and $_ -notmatch [regex]::Escape($allowlistAnchor)
        }
        $violations | Should -BeNullOrEmpty -Because 'teaching paragraph terminology must be limited to the forward-compat glossary allowlist; prose must use decision brief instead'
    }
}

Describe 'solution-authoring platforms parity' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:ClaudePath  = Join-Path $script:RepoRoot 'skills\solution-authoring\platforms\claude.md'
        $script:CopilotPath = Join-Path $script:RepoRoot 'skills\solution-authoring\platforms\copilot.md'

        $script:GetH2Headings = {
            param([string]$Content)
            [regex]::Matches($Content, '(?m)^## (.+)$') | ForEach-Object { $_.Groups[1].Value.Trim() }
        }

        $script:ClaudeContent  = (Get-Content -Path $script:ClaudePath  -Raw -ErrorAction Stop) -replace "`r`n?", "`n"
        $script:CopilotContent = (Get-Content -Path $script:CopilotPath -Raw -ErrorAction Stop) -replace "`r`n?", "`n"
    }

    It 'AC11.b — claude.md exists' {
        $script:ClaudePath | Should -Exist
    }

    It 'AC11.b — copilot.md exists' {
        $script:CopilotPath | Should -Exist
    }

    It 'AC11.b — both platform files have identical H2 section names' {
        $claudeH2s  = & $script:GetH2Headings -Content $script:ClaudeContent
        $copilotH2s = & $script:GetH2Headings -Content $script:CopilotContent
        $claudeH2s  | Should -Not -BeNullOrEmpty -Because 'claude.md must have at least one H2 section'
        $copilotH2s | Should -Not -BeNullOrEmpty -Because 'copilot.md must have at least one H2 section'
        $diff = Compare-Object $claudeH2s $copilotH2s
        $diff | Should -BeNullOrEmpty -Because 'both platform files must have identical H2 section names (parity requirement AC9)'
    }
}

Describe '4-body load directive' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path

        $script:AgentFiles = @(
            'agents\Experience-Owner.agent.md',
            'agents\Solution-Designer.agent.md',
            'agents\Issue-Planner.agent.md',
            'agents\Code-Conductor.agent.md'
        ) | ForEach-Object {
            $fullPath = Join-Path $script:RepoRoot $_
            $content = (Get-Content -Path $fullPath -Raw -ErrorAction Stop) -replace "`r`n?", "`n"
            [pscustomobject]@{
                Name    = $_
                Content = $content
                Lines   = $content -split "`n"
            }
        }

        $script:NewDirectiveSubstring = 'Load `skills/solution-authoring/SKILL.md` first and follow its protocol before any subsequent skill fires a structured question'
        $script:OldFormPrefix = 'When this user-invocable agent receives a request referencing an existing GitHub issue, load `skills/upstream-onboarding/SKILL.md`'
    }

    It 'AC11.c — new directive substring present exactly once per body' {
        foreach ($body in $script:AgentFiles) {
            $count = [regex]::Matches($body.Content, [regex]::Escape($script:NewDirectiveSubstring)).Count
            $count | Should -Be 1 -Because "$($body.Name) must contain the new directive substring exactly once"
        }
    }

    It 'AC11.c — old standalone upstream-onboarding load line absent from all 4 bodies' {
        foreach ($body in $script:AgentFiles) {
            $body.Content | Should -Not -Match ([regex]::Escape($script:OldFormPrefix)) -Because "$($body.Name) must not retain the old-form standalone load line"
        }
    }

    It 'AC11.c — new directive line-index precedes any subsequent skill-load reference in each body' {
        foreach ($body in $script:AgentFiles) {
            $lines = $body.Lines
            $directiveIdx = -1

            for ($i = 0; $i -lt $lines.Count; $i++) {
                if ($lines[$i] -match [regex]::Escape($script:NewDirectiveSubstring)) {
                    $directiveIdx = $i
                    break
                }
            }

            $directiveIdx | Should -BeGreaterOrEqual 0 -Because "$($body.Name) must contain the new directive"

            $nextSkillLoadIdx = [int]::MaxValue
            for ($i = $directiveIdx + 1; $i -lt $lines.Count; $i++) {
                if ($lines[$i] -imatch 'load.*`skills/') {
                    $nextSkillLoadIdx = $i
                    break
                }
            }

            if ($nextSkillLoadIdx -ne [int]::MaxValue) {
                $directiveIdx | Should -BeLessThan $nextSkillLoadIdx -Because "$($body.Name): new directive (line $directiveIdx) must precede next skill-load reference (line $nextSkillLoadIdx)"
            }
        }
    }

    It 'AC11.c — Code-Conductor body explicitly enumerates scope-classification and D9-checkpoint touchpoints' {
        $cc = $script:AgentFiles | Where-Object { $_.Name -like '*Code-Conductor*' }
        $cc.Content | Should -Match 'scope-classification' -Because 'Code-Conductor must enumerate scope-classification as a content-authoring touchpoint near the directive'
        $cc.Content | Should -Match 'D9-checkpoint' -Because 'Code-Conductor must enumerate D9-checkpoint as a content-authoring touchpoint near the directive'
    }
}

Describe 'upstream-onboarding sweep' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:UOPath    = Join-Path $script:RepoRoot 'skills\upstream-onboarding\SKILL.md'
        $script:UOContent = (Get-Content -Path $script:UOPath -Raw -ErrorAction Stop) -replace "`r`n?", "`n"
    }

    It 'AC11.d — anchor d-load-order-resolution-anchor present' {
        $script:UOContent | Should -Match '<!-- d-load-order-resolution-anchor -->' -Because 'anchor must be placed near ## When to Use per AC10'
    }

    It 'AC11.d — frontmatter description field does not contain first load-order claim' {
        $frontmatter = [regex]::Match($script:UOContent, '(?s)^---\n(.+?)\n---').Groups[1].Value
        $frontmatter | Should -Not -Match '\bfirst\b' -Because 'description field must not claim load-first ordering'
    }

    It 'AC11.d — ## When to Use section does not contain first load-order claim' {
        $section = [regex]::Match($script:UOContent, '(?s)## When to Use\n(.+?)(?=\n## )').Groups[1].Value
        $section | Should -Not -Match '\bfirst\b' -Because '## When to Use must not claim load-first ordering'
    }

    It 'AC11.d — ### Sequencing subsection does not contain first load-order claim' {
        $section = [regex]::Match($script:UOContent, '(?s)### Sequencing\n(.+?)(?=\n### |\n## )').Groups[1].Value
        $section | Should -Not -Match '\bfirst\b' -Because '### Sequencing must not claim runs-first ordering'
    }

    It 'AC11.d — removal-step completeness: any remaining first is in the Gotchas allowlist' {
        $violations = ($script:UOContent -split "`n") | Where-Object {
            $_ -imatch '\bfirst\b' -and $_ -notmatch 'completion marker first'
        }
        $violations | Should -BeNullOrEmpty -Because 'any remaining "first" outside the Gotchas allowlist is a violation'
    }
}

Describe 'frame-architecture stacking note' {

    BeforeAll {
        $script:RepoRoot  = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:FAPath    = Join-Path $script:RepoRoot 'Documents\Design\frame-architecture.md'
        $script:FAContent = (Get-Content -Path $script:FAPath -Raw -ErrorAction Stop) -replace "`r`n?", "`n"
    }

    It 'AC11.f — stacking-precedent paragraph present in frame-architecture.md Adapter Model section' {
        $script:FAContent | Should -Match "Two ``provides:``-less supporting methodologies can stack" -Because 'Adapter Model section must document the solution-authoring + upstream-onboarding stacking precedent'
    }

    It 'AC11.f — stacking paragraph names both solution-authoring and upstream-onboarding' {
        $script:FAContent | Should -Match 'solution-authoring' -Because 'stacking paragraph must name solution-authoring'
        $script:FAContent | Should -Match 'upstream-onboarding' -Because 'stacking paragraph must name upstream-onboarding'
    }
}
