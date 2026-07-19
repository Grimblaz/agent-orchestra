#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#!
.SYNOPSIS
    RED-phase contract test for issue #878 s2 (Part A doc-example contract).

.DESCRIPTION
    Extracts every doc-embedded phase-containment example from
    skills/plan-authoring/SKILL.md, skills/design-exploration/SKILL.md, and
    skills/review-judgment/SKILL.md and asserts the production
    Get-PhaseContainmentBlock parser (phase-containment-core.ps1, loaded
    unmodified) accepts each one, byte-identical to a committed canonical
    fixture.

    THIS IS A RED-ONLY STEP (s2). Docs are NOT touched here — that is s3
    ("[GREEN] Part A doc fixes"). This file is authored to describe the
    DESIRED end state; several assertions below are expected to fail today
    and are expected to turn green once s3 lands.

    Why this file exists (M9 / M10 from the plan's stress test): "every
    extracted example parses" is vacuously true over an empty set. Two
    defenses against that trap are structural in this file, not just
    prose:
      1. Every per-variant Context below has its OWN floor It-block
         ("at least N examples"), asserted SEPARATELY from the parse/shape
         It-block, so a floor failure and a shape failure are never
         conflated into one ambiguous red.
      2. The "extractor unit behavior" Context proves the fenced-block
         extractor itself (Get-FencedPhaseContainmentCandidates, defined
         in this file, NOT the production parser) is not silently
         matching zero via synthetic, doc-content-independent fixtures.
         The "anti-vacuous-pass meta-assertion" Context then proves, on
         today's LIVE tree, that at least one section already yields a
         non-zero candidate count — so a hypothetical future regression
         where the extractor always returns empty is itself caught,
         independent of whether s3 has landed.

    Concretization step (M10 — defined explicitly, one canonical example
    per VARIANT, not per section; the three cited shapes use different
    placeholder tokens and must not be treated as one canonical shape):

      - plan-authoring (skills/plan-authoring/SKILL.md:401-404), variant
        "plan-stress-test": placeholders {ID}, {issue}, {marker},
        {finding_id}, PLUS a literal `...` elision line. Concretized here
        as {ID}->878, {issue}->878, {marker}->plan-issue-878,
        {finding_id}->M1. The `...` elision line is NOT expanded — it is
        left exactly as authored, because the doc's live template elides
        the remaining fields rather than spelling them out, and that
        elision is itself part of what makes the doc's declared span
        byte-UNEQUAL to the fully-literal canonical fixture. NOTE: `...`
        is a valid YAML document-end marker, but the hand-rolled parsers
        in this codebase (phase-containment-core.ps1 and this file's own
        extractor) never call ConvertFrom-Yaml / powershell-yaml (file-
        level SECURITY invariant), so `...` is never at risk of being
        mis-interpreted as document-end here — it is simply an unmatched
        line that every regex-based field reader silently skips. It is
        called out here only so a future maintainer does not "fix" this
        test by feeding these strings through a real YAML parser.

      - design-exploration (skills/design-exploration/SKILL.md:206-217),
        variant "design-challenge": same placeholder family as
        plan-authoring ({issue}, {marker}, {finding_id}) — no fenced
        template exists in the doc at all today (only prose bullets), so
        there is nothing to concretize FROM the doc yet; the canonical
        fixture below is the target s3 will add. Concretized reference
        values used by the fixture: {issue}->878,
        {marker}->design-phase-complete-878, {finding_id}->M1.

      - review-judgment code-review variant (:138): placeholder
        {PR}, finding_key shape `code-review:{stable_finding_key}`.
        Concretized reference values: {PR}->879,
        {stable_finding_key}->gh-1234 (matching the
        phase-containment-core.Tests.ps1 precedent's `code-review:gh-1234`
        literal).

      - review-judgment post-review-observer variant (:155-157):
        finding_key shape `post-review-observer:{stable_finding_key}`,
        own caught_stage/escape_distance formula (projection=4).
        Concretized reference values: {PR}->879,
        {stable_finding_key}->gh-5678.

    Judge-rulings dual-reader routing (M30): the plan-surface `- finding_id:`
    shape (plan-authoring/SKILL.md:229-234) and the PR-surface
    `- id:`/`points_awarded` shape (review-judgment/SKILL.md:121-131) are
    two independent schemas (plan-authoring/SKILL.md:255, rule 9) and are
    routed to their own readers below: Get-SustainedFindingCount
    (phase-containment-emission-check-core.ps1, "the emission-check
    reader") for the plan surface, and ConvertFrom-JudgeRulingsComment
    (frame-credit-ledger-core.ps1:1178, PR-surface reader) for the PR
    surface. Both examples are ALREADY correctly shaped in the docs today
    (judge-rulings is bare-by-contract, not paired — the shape-asymmetry
    callout s3 will add), so both assertions below are expected to PASS
    in this red run; they exist to prove the red elsewhere is scoped to
    the phase-containment block shape specifically, not a wholesale
    parser-pipeline failure.
#>

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
    $script:LibRoot = Join-Path $PSScriptRoot '..' 'lib'

    # phase-containment-emission-check-core.ps1 transitively dot-sources
    # phase-containment-core.ps1 at its own :24, so Get-PhaseContainmentBlock
    # is available after this single dot-source.
    . (Join-Path $script:LibRoot 'phase-containment-emission-check-core.ps1')
    . (Join-Path $script:LibRoot 'frame-credit-ledger-core.ps1')

    $script:PlanAuthoringPath = Join-Path $script:RepoRoot 'skills/plan-authoring/SKILL.md'
    $script:DesignExplorationPath = Join-Path $script:RepoRoot 'skills/design-exploration/SKILL.md'
    $script:ReviewJudgmentPath = Join-Path $script:RepoRoot 'skills/review-judgment/SKILL.md'
    $script:FixtureRoot = Join-Path $PSScriptRoot 'fixtures/phase-containment-doc-examples'

    $script:GetNormalizedContent = {
        param([string]$Path)
        (Get-Content -Path $Path -Raw -ErrorAction Stop) -replace "`r`n?", "`n"
    }

    #region Extractor under test (doc-scan layer, NOT the production parser)

    function script:Get-FencedPhaseContainmentCandidates {
        <#
        .SYNOPSIS
            Extracts every fenced (``` ... ```) code-block interior from
            $Text that contains a real phase-containment open-tag mention.
        .DESCRIPTION
            "Extracts from fenced blocks only so callout prose is never fed
            to the parser" (s2 Requirement Contract): a bare-text mention of
            `<!-- phase-containment-{ID} -->` inside a running sentence
            (e.g. design-exploration/SKILL.md:208) is deliberately NOT
            matched — only content inside a ``` fence counts as a
            doc-embedded example. The phase-containment-ledger-{ID} sibling
            pointer sentinel is excluded via a negative lookahead so it is
            never conflated with a real phase-containment block (shared
            "phase-containment-" prefix).
        #>
        param(
            [Parameter(Mandatory)][AllowEmptyString()][string]$Text
        )
        $fenceMatches = [regex]::Matches($Text, '(?s)```[a-zA-Z]*\r?\n(?<body>.*?)```')
        $candidates = [System.Collections.Generic.List[string]]::new()
        foreach ($m in $fenceMatches) {
            $body = $m.Groups['body'].Value
            if ($body -match '<!--\s*phase-containment-(?!ledger-)\S+') {
                $candidates.Add($body)
            }
        }
        return , $candidates.ToArray()
    }

    function script:Get-DeclaredPhaseContainmentSpan {
        <#
        .SYNOPSIS
            Isolates the raw declared phase-containment span inside an
            already-matched candidate, from the open-tag-ish line through
            the next closing-like line.
        .DESCRIPTION
            Intentionally shape-agnostic: does not assume the doc already
            uses the paired-tag convention (`<!-- phase-containment-{ID} -->`
            ... `<!-- /phase-containment-{ID} -->`), because at RED time it
            does not — the live plan-authoring template is the bare/unclosed
            "yaml inside one comment" shape this issue's s3 replaces. A
            closing line is either a bare `-->` (today's wrong shape) or a
            proper `<!-- /phase-containment-{id} -->` close tag (the target
            shape), whichever is found first after the open line.
        #>
        param(
            [Parameter(Mandatory)][string]$CandidateText
        )
        $lines = $CandidateText -split "`n"
        $openIdx = -1
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match '^\s*<!--\s*phase-containment-(?!ledger-)\S+') {
                $openIdx = $i
                break
            }
        }
        if ($openIdx -lt 0) { return $null }
        $closeIdx = -1
        for ($j = $openIdx; $j -lt $lines.Count; $j++) {
            if ($lines[$j].Trim() -eq '-->' -or $lines[$j] -match '^\s*<!--\s*/phase-containment-\S+\s*-->\s*$') {
                $closeIdx = $j
                break
            }
        }
        if ($closeIdx -lt 0) { return $null }
        return ($lines[$openIdx..$closeIdx] -join "`n")
    }

    function script:Set-PhaseContainmentPlaceholders {
        param(
            [Parameter(Mandatory)][AllowNull()][string]$Text,
            [Parameter(Mandatory)][hashtable]$Substitutions
        )
        if ($null -eq $Text) { return $null }
        $result = $Text
        foreach ($key in $Substitutions.Keys) {
            $result = $result.Replace($key, [string]$Substitutions[$key])
        }
        return $result
    }

    #endregion

    $script:PlanAuthoringContent = & $script:GetNormalizedContent -Path $script:PlanAuthoringPath
    $script:DesignExplorationContent = & $script:GetNormalizedContent -Path $script:DesignExplorationPath
    $script:ReviewJudgmentContent = & $script:GetNormalizedContent -Path $script:ReviewJudgmentPath

    $script:PlanAuthoringCandidates = Get-FencedPhaseContainmentCandidates -Text $script:PlanAuthoringContent
    $script:DesignExplorationCandidates = Get-FencedPhaseContainmentCandidates -Text $script:DesignExplorationContent
    $script:ReviewJudgmentCandidates = Get-FencedPhaseContainmentCandidates -Text $script:ReviewJudgmentContent
}

Describe 'Doc-embedded phase-containment examples (issue #878 s2, RED)' {

    Context 'plan-authoring: plan-stress-test variant (SKILL.md:401-404)' {
        It 'the doc contains at least one fenced phase-containment example (extractor floor)' {
            $script:PlanAuthoringCandidates.Count | Should -BeGreaterOrEqual 1 -Because 'the Plan-markdown template section already carries one (wrongly-shaped) fenced example; a floor failure here would mean the doc lost it, not that the shape is wrong'
        }

        It 'the concretized doc example is byte-identical to the committed canonical paired-shape fixture' {
            $span = Get-DeclaredPhaseContainmentSpan -CandidateText $script:PlanAuthoringCandidates[0]
            $span | Should -Not -BeNullOrEmpty -Because 'a declared phase-containment span must be locatable inside the matched candidate'

            $concretized = Set-PhaseContainmentPlaceholders -Text $span -Substitutions @{
                '{ID}'         = '878'
                '{issue}'      = '878'
                '{marker}'     = 'plan-issue-878'
                '{finding_id}' = 'M1'
            }
            $fixture = (Get-Content -Raw (Join-Path $script:FixtureRoot 'plan-stress-test.phase-containment.txt')) -replace "`r`n?", "`n"

            $concretized.Trim() | Should -BeExactly $fixture.Trim() -Because 'AC1: the live template is still the bare/unclosed shape (open tag has no trailing "-->" and closes with a bare "-->" instead of "<!-- /phase-containment-878 -->"), plus a literal "..." elision line instead of fully-literal fields — neither matches the paired, fully-literal canonical fixture s3 will add'
        }

        It 'the concretized doc example parses via the production Get-PhaseContainmentBlock parser' {
            $span = Get-DeclaredPhaseContainmentSpan -CandidateText $script:PlanAuthoringCandidates[0]
            $concretized = Set-PhaseContainmentPlaceholders -Text $span -Substitutions @{
                '{ID}'         = '878'
                '{issue}'      = '878'
                '{marker}'     = 'plan-issue-878'
                '{finding_id}' = 'M1'
            }

            $result = Get-PhaseContainmentBlock -Text $concretized -Id '878'

            $result | Should -Not -BeNullOrEmpty -Because 'Get-PhaseContainmentBlock requires both a self-closed open tag "<!-- phase-containment-878 -->" and a separate "<!-- /phase-containment-878 -->" close tag; the live template supplies neither (this is the shape failure AC1 exists to close, not an extraction bug — the floor test above already proved extraction found the block)'
        }
    }

    Context 'design-exploration: design-challenge variant (SKILL.md:206-217)' {
        It 'the doc contains at least one fenced phase-containment example (extractor floor)' {
            $script:DesignExplorationCandidates.Count | Should -BeGreaterOrEqual 1 -Because 'AC1 requires one fully literal canonical example in this section; today the section is prose-bullets-only with no fenced example at all (s3 adds it)'
        }

        It 'the concretized doc example is byte-identical to the committed canonical paired-shape fixture' {
            $span = Get-DeclaredPhaseContainmentSpan -CandidateText $script:DesignExplorationCandidates[0]
            $span | Should -Not -BeNullOrEmpty -Because 'a declared phase-containment span must be locatable inside the matched candidate'

            $concretized = Set-PhaseContainmentPlaceholders -Text $span -Substitutions @{}
            $fixture = (Get-Content -Raw (Join-Path $script:FixtureRoot 'design-challenge.phase-containment.txt')) -replace "`r`n?", "`n"

            $concretized.Trim() | Should -BeExactly $fixture.Trim() -Because 'AC1: the design-challenge example (SKILL.md:206-217) is already fully literal (no placeholders left) and must match the committed canonical fixture byte-for-byte'
        }

        It 'the concretized doc example parses via the production Get-PhaseContainmentBlock parser' {
            $span = Get-DeclaredPhaseContainmentSpan -CandidateText $script:DesignExplorationCandidates[0]
            $concretized = Set-PhaseContainmentPlaceholders -Text $span -Substitutions @{}

            $result = Get-PhaseContainmentBlock -Text $concretized -Id '878'

            $result | Should -Not -BeNullOrEmpty -Because 'Get-PhaseContainmentBlock requires both a self-closed open tag "<!-- phase-containment-878 -->" and a separate "<!-- /phase-containment-878 -->" close tag; the design-challenge example already supplies both'
        }
    }

    Context 'review-judgment: code-review variant (SKILL.md:138)' {
        It 'the doc contains at least one fenced phase-containment example (extractor floor)' {
            $script:ReviewJudgmentCandidates.Count | Should -BeGreaterOrEqual 1 -Because 'AC1 requires one fully literal canonical example for the code-review variant; today the section is prose-bullets-only with no fenced example at all (s3 adds it; AC6 scopes the emission routing itself out of this step)'
        }

        It 'the concretized doc example is byte-identical to the committed canonical paired-shape fixture' {
            $span = Get-DeclaredPhaseContainmentSpan -CandidateText $script:ReviewJudgmentCandidates[0]
            $span | Should -Not -BeNullOrEmpty -Because 'a declared phase-containment span must be locatable inside the matched candidate'

            $concretized = Set-PhaseContainmentPlaceholders -Text $span -Substitutions @{}
            $fixture = (Get-Content -Raw (Join-Path $script:FixtureRoot 'code-review.phase-containment.txt')) -replace "`r`n?", "`n"

            $concretized.Trim() | Should -BeExactly $fixture.Trim() -Because 'AC1: the code-review example (SKILL.md:149-164) is already fully literal (no placeholders left) and must match the committed canonical fixture byte-for-byte'
        }

        It 'the concretized doc example parses via the production Get-PhaseContainmentBlock parser' {
            $span = Get-DeclaredPhaseContainmentSpan -CandidateText $script:ReviewJudgmentCandidates[0]
            $concretized = Set-PhaseContainmentPlaceholders -Text $span -Substitutions @{}

            $result = Get-PhaseContainmentBlock -Text $concretized -Id '879'

            $result | Should -Not -BeNullOrEmpty -Because 'Get-PhaseContainmentBlock requires both a self-closed open tag "<!-- phase-containment-879 -->" and a separate "<!-- /phase-containment-879 -->" close tag; the code-review example already supplies both'
        }
    }

    Context 'review-judgment: post-review-observer variant (SKILL.md:155-157)' {
        It 'the doc contains at least one fenced phase-containment example distinct from the code-review variant (extractor floor)' {
            # Both review-judgment variants are counted from the same
            # ReviewJudgmentCandidates set (one file); AC1 requires 2 literal
            # examples in this file post-s3 (one per variant), so the floor
            # here is >= 2, not >= 1 -- a single shared example would satisfy
            # only the code-review variant and leave this one uncovered.
            $script:ReviewJudgmentCandidates.Count | Should -BeGreaterOrEqual 2 -Because 'AC1 requires one canonical example PER VARIANT, not per section (M10) -- review-judgment alone has two variants (code-review, post-review-observer) and today has zero fenced examples for either'
        }

        It 'the concretized doc example is byte-identical to the committed canonical paired-shape fixture' {
            $span = Get-DeclaredPhaseContainmentSpan -CandidateText $script:ReviewJudgmentCandidates[1]
            $span | Should -Not -BeNullOrEmpty -Because 'a declared phase-containment span must be locatable inside the matched candidate -- this is the SECOND review-judgment candidate (index 1), distinct from the code-review variant at index 0'

            $concretized = Set-PhaseContainmentPlaceholders -Text $span -Substitutions @{}
            $fixture = (Get-Content -Raw (Join-Path $script:FixtureRoot 'post-review-observer.phase-containment.txt')) -replace "`r`n?", "`n"

            $concretized.Trim() | Should -BeExactly $fixture.Trim() -Because 'AC1: the post-review-observer example (SKILL.md:177-191) is already fully literal (no placeholders left) and must match the committed canonical fixture byte-for-byte'
        }

        It 'the concretized doc example parses via the production Get-PhaseContainmentBlock parser' {
            $span = Get-DeclaredPhaseContainmentSpan -CandidateText $script:ReviewJudgmentCandidates[1]
            $concretized = Set-PhaseContainmentPlaceholders -Text $span -Substitutions @{}

            $result = Get-PhaseContainmentBlock -Text $concretized -Id '879'

            $result | Should -Not -BeNullOrEmpty -Because 'Get-PhaseContainmentBlock requires both a self-closed open tag "<!-- phase-containment-879 -->" and a separate "<!-- /phase-containment-879 -->" close tag; the post-review-observer example already supplies both'
        }
    }

    Context 'judge-rulings dual-reader routing (M30 — two independent schemas, not interchangeable)' {
        It 'plan-surface "- finding_id:" shape (plan-authoring/SKILL.md:229-234) parses via Get-SustainedFindingCount' {
            # Concretization: {finding_id} -> M1, {sustained | defense-sustained} -> sustained.
            $planSurfaceExample = @"
<!-- judge-rulings
- finding_id: M1
  judge_ruling: sustained
-->
"@
            $result = Get-SustainedFindingCount -Body $planSurfaceExample -Surface 'plan-stress-test'

            $result.ParseStatus | Should -Be 'ok' -Because 'the plan-surface shape is already correctly authored in the doc today — this is expected to pass, isolating the red elsewhere to the phase-containment block shape specifically'
            $result.SustainedCount | Should -Be 1
        }

        It 'PR-surface "- id:"/"points_awarded" shape (review-judgment/SKILL.md:121-131) parses via ConvertFrom-JudgeRulingsComment' {
            # Fully literal in the doc already -- no placeholders to concretize.
            $prSurfaceExample = @"
<!-- judge-rulings
- id: F1
  judge_ruling: sustained
  judge_confidence: high
  points_awarded: P+10
- id: F2
  judge_ruling: defense-sustained
  judge_confidence: medium
  points_awarded: D+5
-->
"@
            $rows = ConvertFrom-JudgeRulingsComment -CommentBody $prSurfaceExample

            $rows.Count | Should -Be 2 -Because 'the PR-surface shape is already correctly authored in the doc today — this is expected to pass'
            $rows[0].id | Should -Be 'F1'
            $rows[0].points_awarded | Should -Be 'P+10'
            $rows[1].judge_ruling | Should -Be 'defense-sustained'
        }
    }

    Context 'extractor unit behavior (synthetic fixtures, doc-content-independent)' {
        It 'ignores a prose-only marker mention outside any fenced block' {
            $text = 'Some prose that says `<!-- phase-containment-999 -->` inline, never fenced.'
            (Get-FencedPhaseContainmentCandidates -Text $text).Count | Should -Be 0
        }

        It 'excludes the phase-containment-ledger sibling-pointer sentinel from matching' {
            $text = @'
```markdown
<!-- phase-containment-ledger-878 -->
```
'@
            (Get-FencedPhaseContainmentCandidates -Text $text).Count | Should -Be 0
        }

        It 'matches a real fenced phase-containment marker' {
            $text = @'
```markdown
<!-- phase-containment-878 -->
finding_key: code-review:gh-1
<!-- /phase-containment-878 -->
```
'@
            (Get-FencedPhaseContainmentCandidates -Text $text).Count | Should -Be 1
        }
    }

    Context 'anti-vacuous-pass meta-assertion (M9)' {
        It 'proves the fenced-block extractor is not silently matching zero across every section' {
            $total = $script:PlanAuthoringCandidates.Count + $script:DesignExplorationCandidates.Count + $script:ReviewJudgmentCandidates.Count
            $total | Should -BeGreaterThan 0 -Because 'plan-authoring already carries a (wrongly-shaped) fenced example today; if this sum is ever 0 the extractor regex itself regressed, not just doc content -- this is the meta-assertion that keeps "every extracted example parses" from going vacuously green over an empty set'
        }
    }
}
