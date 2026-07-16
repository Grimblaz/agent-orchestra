#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    Contract tests for the Session-Cost Discipline rules introduced by issue #474.

.DESCRIPTION
    Ownership boundary: this file owns the `## Session-Cost Discipline` section in
    skills/terminal-hygiene/SKILL.md and its downstream join references. It does NOT
    own, assert, or regress any pre-existing heading in that file (`## Pester Scope`,
    `` ## `isBackground` Default ``, `## No Terminal/Subagent Batching`,
    `## Terminal Cleanup`, `## Terminal Retry Hygiene`, `## Gotchas`, or the two
    issue-#524 headings) — those remain owned by
    `.github/scripts/Tests/terminal-hygiene-guardrails.Tests.ps1`.

    Prior art: this suite reuses the section-scoped extraction pattern (`GetH2Section`),
    the anchored-H2 assertion shape, and the bare-literal join-assertion shape from
    `terminal-hygiene-guardrails.Tests.ps1` (`:45-53`, `:74`, `:117-122`). The gap-chain
    `.{0,N}` regex style used in `branch-authority-gate-contract.Tests.ps1` is
    deliberately not used here (owner decision `d-regex-timeout-disposition`,
    plan-issue-474): the timeout concern that motivated gap-chain guarding does not
    transfer to this test's hardcoded literals, and no gap-chain patterns are used.

    Assertion coverage (ac-refs: AC2 — this file authors s1; the section body,
    Conductor bullet, and upstream references it locks are authored in s2-s4):
        (a) `## Session-Cost Discipline` H2 heading exists in SKILL.md, line-anchored
        (b) Each of the four rules' distinctive phrases exists, scoped to the
            extracted `## Session-Cost Discipline` section body only (not flat-file
            matched — `batch`/`subagent` vocabulary already exists elsewhere in
            SKILL.md, and rule-1 vocabulary already exists in Code-Conductor.agent.md)
        (c) A pure-pointer bullet naming `Session-Cost Discipline` exists inside
            Code-Conductor.agent.md's `## Ownership Principles` section body only
            (scoped between the heading and the `<critical_rules>` boundary)
        (d) Per-file join-lock, decomposed per file (not one conjoined assertion):
            each of Code-Conductor.agent.md, Experience-Owner.agent.md,
            Solution-Designer.agent.md, and Issue-Planner.agent.md must contain the
            unanchored, escaped bare literal `Session-Cost Discipline`
        (e) The frontmatter `description:` of SKILL.md names session-cost discipline
#>

Describe 'session-cost discipline contract' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:SkillPath      = Join-Path $script:RepoRoot 'skills/terminal-hygiene/SKILL.md'
        $script:ConductorPath  = Join-Path $script:RepoRoot 'agents/Code-Conductor.agent.md'
        $script:ExperiencePath = Join-Path $script:RepoRoot 'agents/Experience-Owner.agent.md'
        $script:DesignerPath   = Join-Path $script:RepoRoot 'agents/Solution-Designer.agent.md'
        $script:PlannerPath    = Join-Path $script:RepoRoot 'agents/Issue-Planner.agent.md'

        $script:SectionHeading = '## Session-Cost Discipline'

        # Load file content normalized to LF line endings
        $script:GetContent = {
            param([string]$Path)
            (Get-Content -Path $Path -Raw -ErrorAction Stop) -replace "`r`n?", "`n"
        }

        # Extract the body of a named H2 section.
        # Returns content from the line after the heading up to the next '## ' heading or EOF.
        # Uses section-scoped extraction to avoid cross-section false-GREENs.
        $script:GetH2Section = {
            param([string]$Content, [string]$Heading)
            $escaped = [regex]::Escape($Heading)
            $pattern = "(?ms)^$escaped[^\n]*\n(?<body>.*?)(?=^## |\z)"
            $m = [regex]::Match($Content, $pattern)
            if (-not $m.Success) { return '' }
            return $m.Groups['body'].Value
        }

        # Extract the body between a named heading and a literal end-marker string
        # (rather than the next '## ' heading). Used to scope the Code-Conductor
        # Ownership Principles bullet check to its documented bounds
        # (`## Ownership Principles` heading -> `<critical_rules>` boundary).
        $script:GetBoundedSection = {
            param([string]$Content, [string]$StartHeading, [string]$EndMarker)
            $escapedStart = [regex]::Escape($StartHeading)
            $escapedEnd = [regex]::Escape($EndMarker)
            $pattern = "(?ms)^$escapedStart[^\n]*\n(?<body>.*?)(?=$escapedEnd)"
            $m = [regex]::Match($Content, $pattern)
            if (-not $m.Success) { return '' }
            return $m.Groups['body'].Value
        }

        # Extract the YAML frontmatter block (between the first two '---' delimiters).
        $script:GetFrontmatter = {
            param([string]$Content)
            $pattern = '(?ms)\A---\n(?<body>.*?)\n---'
            $m = [regex]::Match($Content, $pattern)
            if (-not $m.Success) { return '' }
            return $m.Groups['body'].Value
        }

        # Load all target files
        $script:SkillContent      = if (Test-Path $script:SkillPath)      { & $script:GetContent -Path $script:SkillPath }      else { '' }
        $script:ConductorContent  = if (Test-Path $script:ConductorPath)  { & $script:GetContent -Path $script:ConductorPath }  else { '' }
        $script:ExperienceContent = if (Test-Path $script:ExperiencePath) { & $script:GetContent -Path $script:ExperiencePath } else { '' }
        $script:DesignerContent   = if (Test-Path $script:DesignerPath)   { & $script:GetContent -Path $script:DesignerPath }   else { '' }
        $script:PlannerContent    = if (Test-Path $script:PlannerPath)    { & $script:GetContent -Path $script:PlannerPath }    else { '' }
    }

    # (a) The Session-Cost Discipline H2 heading exists in SKILL.md, line-anchored
    It 'requires the Session-Cost Discipline H2 heading to be present in terminal-hygiene SKILL.md' {
        $script:SkillContent | Should -Match '(?m)^## Session-Cost Discipline\s*$' `
            -Because 'AC2: Session-Cost Discipline section must be added to SKILL.md'
    }

    # (b) Each of the four rules' distinctive phrases exists, section-scoped.
    # IMPORTANT: 'batch' and 'subagent' vocabulary already appears elsewhere in
    # SKILL.md (## No Terminal/Subagent Batching). A flat-file regex would false-GREEN
    # before s2 authors the section. These assertions are scoped to the extracted
    # section body to prevent that.
    It 'requires the Session-Cost Discipline section to state all four rules' {
        $sectionBody = & $script:GetH2Section -Content $script:SkillContent -Heading $script:SectionHeading

        $sectionBody | Should -Match 'never dispatch a subagent for a check the parent could do' `
            -Because 'rule 1 (parent-side diagnostics) must be stated in the section body'
        $sectionBody | Should -Match "never let ``gh view`` output become the write payload" `
            -Because 'rule 2 (targeted edits, split by target) must be stated in the section body'
        $sectionBody | Should -Match 'batch independent tool calls in one message' `
            -Because 'rule 3 (batch independent tool calls) must be stated in the section body'
        $sectionBody | Should -Match 'extract at the tool boundary' `
            -Because 'rule 4 (extract at the tool boundary) must be stated in the section body'
    }

    # (c) A pure-pointer bullet naming Session-Cost Discipline exists inside
    # Code-Conductor.agent.md's Ownership Principles section body only.
    # IMPORTANT: scoped between the '## Ownership Principles' heading and the
    # '<critical_rules>' boundary so a load reference elsewhere in the file
    # (e.g. the existing terminal-hygiene load reference) cannot false-GREEN this check.
    It 'requires a pure-pointer bullet naming Session-Cost Discipline inside Code-Conductor Ownership Principles' {
        $ownershipBody = & $script:GetBoundedSection -Content $script:ConductorContent `
            -StartHeading '## Ownership Principles' -EndMarker '<critical_rules>'

        $ownershipBody | Should -Match ([regex]::Escape('Session-Cost Discipline')) `
            -Because 'Ownership Principles must carry a pointer bullet naming Session-Cost Discipline, not a restatement'
        $ownershipBody | Should -Not -Match 'dispatch a subagent for a check' `
            -Because 'the Ownership Principles bullet must be a pure pointer (plan Step 3, judge-sustained M14) - rule 1 operative text belongs only in the skill section, never restated in the conductor body'
    }

    # (d) Per-file join-lock, decomposed per file (not one conjoined assertion) so
    # each downstream slice (s3: Conductor; s4: the three upstream bodies) has an
    # independently meetable exit criterion.
    It 'requires Code-Conductor.agent.md to join-reference Session-Cost Discipline' {
        $script:ConductorContent | Should -Match ([regex]::Escape('Session-Cost Discipline')) `
            -Because 'Code-Conductor.agent.md must reference Session-Cost Discipline by name'
    }

    It 'requires Experience-Owner.agent.md to join-reference Session-Cost Discipline' {
        $script:ExperienceContent | Should -Match ([regex]::Escape('Session-Cost Discipline')) `
            -Because 'Experience-Owner.agent.md must reference Session-Cost Discipline by name'
    }

    It 'requires Solution-Designer.agent.md to join-reference Session-Cost Discipline' {
        $script:DesignerContent | Should -Match ([regex]::Escape('Session-Cost Discipline')) `
            -Because 'Solution-Designer.agent.md must reference Session-Cost Discipline by name'
    }

    It 'requires Issue-Planner.agent.md to join-reference Session-Cost Discipline' {
        $script:PlannerContent | Should -Match ([regex]::Escape('Session-Cost Discipline')) `
            -Because 'Issue-Planner.agent.md must reference Session-Cost Discipline by name'
    }

    # (e) The frontmatter description names session-cost discipline (scoped to the
    # frontmatter block so a later mention of the phrase in the body cannot false-GREEN).
    It 'requires the SKILL.md frontmatter description to name session-cost discipline' {
        $frontmatter = & $script:GetFrontmatter -Content $script:SkillContent

        $frontmatter | Should -Match '(?i)session-cost discipline' `
            -Because 'AC2: frontmatter description must name session-cost discipline'
    }
}
