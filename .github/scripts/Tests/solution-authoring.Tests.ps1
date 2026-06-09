#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#!
.SYNOPSIS
    Contract tests for the solution-authoring skill body and structural assertions.

.DESCRIPTION
    Locks issue #574: the solution-authoring skill body codifies the 7 D-X decisions
    with the correct shape (6 rule + 5 template sections, no provides:, decision-brief
    terminology, forward-compat note preserving teaching_paragraph_excerpt, and
    recommendation-shift token present).
#>

Describe 'solution-authoring SKILL body' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:SkillPath = Join-Path $script:RepoRoot 'skills/solution-authoring/SKILL.md'
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

    It 'AC11.a — body is at or under 300 lines' {
        # Cap raised 200→300 in issue #617: L0 Gate Token + L2 Reconciliation Gate
        # sections (75 lines) are genuine new methodology, not bloat.
        $lineCount = ($script:Content -split "`n").Count
        $lineCount | Should -BeLessOrEqual 300 -Because 'body must stay under the 300-line cap (raised from 200 in #617 for L0/L2 sections)'
    }

    It 'AC11.a — contains exactly 6 ### Rule: sections' {
        $ruleMatches = [regex]::Matches($script:Content, '(?m)^### Rule:')
        $ruleMatches.Count | Should -Be 6 -Because 'body must have exactly 6 rule sections'
    }

    It 'AC5 — contains exactly 5 decline engagement option labels' {
        $declineLabel = 'Decline engagement — proceed without classification'
        $labelMatches = [regex]::Matches($script:Content, [regex]::Escape($declineLabel))
        $labelMatches.Count | Should -Be 5 -Because 'body must include the decline engagement option label exactly 5 times'
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

    It 'AC11.e — same-decision-resume rule activated with Read-EngagementRecords reference' {
        $script:Content | Should -Match 'Read-EngagementRecords' -Because 'same-decision-resume must reference the helper after #575 activation'
        $script:Content | Should -Not -Match '<!-- v0: do not apply; see #575' -Because 'v0 deferral comment must be removed after #575 activation'
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
        $script:ClaudePath  = Join-Path $script:RepoRoot 'skills/solution-authoring/platforms/claude.md'
        $script:CopilotPath = Join-Path $script:RepoRoot 'skills/solution-authoring/platforms/copilot.md'

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

    It 'AC11.c — Code-Conductor body explicitly enumerates scope-classification touchpoint' {
        $cc = $script:AgentFiles | Where-Object { $_.Name -like '*Code-Conductor*' }
        $cc.Content | Should -Match 'scope-classification' -Because 'Code-Conductor must enumerate scope-classification as a content-authoring touchpoint near the directive'
    }

    It 'AC11.c-neg — Code-Conductor body does NOT enumerate D9-checkpoint as a solution-authoring touchpoint (D-577 narrowing lock)' {
        $cc = $script:AgentFiles | Where-Object { $_.Name -like '*Code-Conductor*' }
        # The line-117 touchpoint sentence must not list D9-checkpoint as a content-authoring touchpoint.
        # D9 remains referenced elsewhere in the body (Allowed D9 values, D9 Model-Switch Checkpoint section) —
        # this assertion targets only the solution-authoring touchpoint enumeration sentence.
        $touchpointSentence = [regex]::Match($cc.Content, 'Content-authoring touchpoints where the solution-authoring classification gate applies in this agent:[^.]+\.').Value
        $touchpointSentence | Should -Not -BeNullOrEmpty -Because 'touchpoint enumeration sentence must exist in the body'
        $touchpointSentence | Should -Not -Match 'D9-checkpoint' -Because 'D-577 narrowed the touchpoint set to scope-classification only; D9-checkpoint must not reappear without an explicit re-audit'
    }
}

Describe 'upstream-onboarding sweep' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:UOPath    = Join-Path $script:RepoRoot 'skills/upstream-onboarding/SKILL.md'
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

Describe 'escalation tier — issue #556 structural assertions' {

    BeforeAll {
        $script:RepoRoot     = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:SkillPath    = Join-Path $script:RepoRoot 'skills/solution-authoring/SKILL.md'
        $script:Content      = (Get-Content -Path $script:SkillPath -Raw -ErrorAction Stop) -replace "`r`n?", "`n"
        $script:ClaudeMdPath = Join-Path $script:RepoRoot 'skills/solution-authoring/platforms/claude.md'
        $script:ClaudeMdContent = (Get-Content -Path $script:ClaudeMdPath -Raw -ErrorAction Stop) -replace "`r`n?", "`n"
        $copilotMdPath = Join-Path $script:RepoRoot 'skills/solution-authoring/platforms/copilot.md'
        $script:CopilotMdContent = (Get-Content -Path $copilotMdPath -Raw -ErrorAction Stop) -replace "`r`n?", "`n"
        $script:SDAgentPath  = Join-Path $script:RepoRoot 'agents/Solution-Designer.agent.md'
        $script:SDContent    = (Get-Content -Path $script:SDAgentPath -Raw -ErrorAction Stop) -replace "`r`n?", "`n"
        $script:DEPath       = Join-Path $script:RepoRoot 'skills/design-exploration/SKILL.md'
        $script:DEContent    = (Get-Content -Path $script:DEPath -Raw -ErrorAction Stop) -replace "`r`n?", "`n"
    }

    # AC1 — escalation tier text
    It 'AC1 — SKILL.md contains the text "escalation tier"' {
        $script:Content | Should -Match 'escalation tier'
    }

    # AC2 — trigger language
    It 'AC2 — SKILL.md contains trigger phrase "load-bearing adversarial-review"' {
        $script:Content | Should -Match 'load-bearing adversarial-review'
    }

    # AC3 — positive routing for incorporate/dismiss
    It 'AC3 — SKILL.md escalation tier covers load-bearing dispositions regardless of incorporate/dismiss/escalate outcome' {
        $script:Content | Should -Match 'regardless of whether their final outcome is'
        $script:Content | Should -Match 'incorporate'
        $script:Content | Should -Match 'dismiss'
    }

    # MF3 — base tier presence
    It 'MF3 — SKILL.md routing partition defines base tier (all other load-bearing decisions)' {
        $script:Content | Should -Match 'base tier'
        $script:Content | Should -Match 'all other load-bearing decisions'
    }

    # AC4 — evidence fallback chain
    It 'AC4 — SKILL.md contains "file:line" (evidence requirement for escalation tier)' {
        $script:Content | Should -Match 'file:line'
    }

    # AC5 — substantiveness criterion
    It 'AC5 (escalation) — SKILL.md contains "substantive" (CE-Gate-evaluated substantiveness criterion)' {
        $script:Content | Should -Match 'substantive'
    }

    # AC5 — re-audit tier re-evaluation
    It 'AC5 — SKILL.md contains classification-re-audit paired with tier re-evaluation' {
        $script:Content | Should -Match 'classification-re-audit.{0,500}tier|tier.{0,500}classification-re-audit'
    }

    # AC8 — Named-Decisions field invariant: Decision brief excerpt stays one sentence
    It 'AC8 — Solution-Designer.agent.md Decision brief excerpt field carries {one sentence} literal' {
        $script:SDContent | Should -Match 'Decision brief excerpt.*\{one sentence\}'
    }

    # AC9 — platform mirrors reference both tiers (RED until s5)
    It 'AC9 — skills/solution-authoring/platforms/claude.md and copilot.md reference "escalation tier"' {
        $script:ClaudeMdContent | Should -Match 'escalation tier'
        $script:CopilotMdContent | Should -Match 'escalation tier'
    }

    # AC6 / s3 — design-exploration/SKILL.md no longer cites feedback_explain_before_options
    It 'AC6 — skills/design-exploration/SKILL.md does not cite "feedback_explain_before_options"' {
        $script:DEContent | Should -Not -Match 'feedback_explain_before_options'
    }
}

Describe 'frame-architecture stacking note' {

    BeforeAll {
        $script:RepoRoot  = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:FAPath    = Join-Path $script:RepoRoot 'Documents/Design/frame-architecture.md'
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
