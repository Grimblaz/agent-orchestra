#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
.SYNOPSIS
    Contract tests for the brief plan variant (issue #941, chunk 3 of #936).

.DESCRIPTION
    Three contracts under test:

      1. Plan structural validation recognises `plan-variant: brief` as a lawful
         plan shape, accepts a brief carrying the sections the doctrine requires,
         REJECTS a document that declares itself a brief while carrying none of
         them, and still rejects a plan that is neither brief, spine-bearing, nor
         a declared variant. (#941 AC2)

      2. Every dispatch point that actually selects a review adapter routes a
         brief-shaped chunk plan to the prosecution-only `design-challenge`
         shape, while code review's `standard` adapter is untouched. (#941 AC4)

      3. The brief conformance check is reachable from where a reviewer works,
         and covers the five properties the doctrine names -- the four
         near-mechanical ones #936 D5 named, plus the vacuity reading-property
         #957 D2 added. (#941 AC6; extended by #973)

      4. The brief-review teeth #957 chunk 2 delivered are held, not merely
         described: the vacuity question is a required part of a brief-target
         convergence cold read AND has an instructed producer, and the routing
         call is a named review target with every outcome arm defined. (#973)
#>

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
    $script:LibFile = Join-Path $script:RepoRoot '.github/scripts/lib/frame-validate-core.ps1'
    . $script:LibFile

    # A minimally-conforming brief: the six numbered sections the two shipped
    # briefs (#939, #941) both carry, read from those artifacts rather than
    # inferred from one sample.
    #
    # These headings are DELIBERATELY restated here rather than generated from
    # $script:FVBriefRequiredSections, and the duplication is the point: a
    # fixture derived from the constant would let a wrong constant validate
    # itself, and it would destroy the number<->name coupling that makes a
    # renumber of that constant turn this suite red. The constant is separately
    # pinned to the doctrine below ("pins the required-section list ..."), so
    # the two are one authoritative list plus one independent expectation —
    # a contract test — not two sources of truth.
    $script:NewBriefPlan = {
        param(
            [string[]]$OmitSections = @(),
            [string]$ExtraBody = '',
            [string]$Frontmatter = "status: pending`npriority: p2`nissue_id: 941`ncreated: 2026-07-28`nce_gate: true`nplan-variant: brief"
        )

        $sections = [ordered]@{
            '1' = '## 1. Problem and observed evidence'
            '2' = '## 2. Epistemic map'
            '3' = '## 3. Acceptance criteria'
            '4' = '## 4. Falsifiers — executor guidance, not checks'
            '5' = '## 5. Context inventory'
            '6' = '## 6. Evidence obligations'
        }

        $body = [System.Collections.Generic.List[string]]::new()
        $body.Add('<!-- plan-issue-941 -->') | Out-Null
        $body.Add('') | Out-Null
        $body.Add('---') | Out-Null
        foreach ($line in ($Frontmatter -split "`n")) { $body.Add($line) | Out-Null }
        $body.Add('---') | Out-Null
        $body.Add('') | Out-Null
        $body.Add('## Plan: A brief-shaped chunk plan') | Out-Null
        $body.Add('') | Out-Null
        foreach ($key in $sections.Keys) {
            if ($OmitSections -contains $key) { continue }
            $body.Add($sections[$key]) | Out-Null
            $body.Add('') | Out-Null
            $body.Add('Prose for this section.') | Out-Null
            $body.Add('') | Out-Null
        }
        if ($ExtraBody) { $body.Add($ExtraBody) | Out-Null }

        return ($body.ToArray() -join "`n")
    }

    $script:GetCheck = {
        param($Result, [string]$Name)
        return (@($Result.Results) | Where-Object { $_.Name -eq $Name } | Select-Object -First 1)
    }

    $script:ReadRepoFile = {
        param([string]$RelativePath)
        return (Get-Content -LiteralPath (Join-Path $script:RepoRoot $RelativePath) -Raw -ErrorAction Stop)
    }
}

Describe 'Brief plan variant — structural validation' -Tag 'unit' {

    It 'accepts a brief carrying every section the doctrine requires' {
        $result = Invoke-FVPlanValidate -CommentText (& $script:NewBriefPlan)

        $structural = & $script:GetCheck $result 'PlanStructuralCoverage'
        $structural | Should -Not -BeNullOrEmpty
        $structural.Passed | Should -BeTrue -Because "a conforming brief must validate: $($structural.Detail)"
        $result.ExitCode | Should -Be 0
    }

    It 'rejects a document that declares itself a brief while carrying none of the required sections' {
        $result = Invoke-FVPlanValidate -CommentText (& $script:NewBriefPlan -OmitSections @('1', '2', '3', '4', '5', '6'))

        $structural = & $script:GetCheck $result 'PlanStructuralCoverage'
        $structural.Passed | Should -BeFalse -Because 'recognising the token is not validating the shape'
        $result.ExitCode | Should -Not -Be 0

        # Every missing section is named, not just the first.
        foreach ($name in @('Problem and observed evidence', 'Epistemic map', 'Acceptance criteria', 'Falsifiers', 'Context inventory', 'Evidence obligations')) {
            $structural.Detail.Contains($name) | Should -BeTrue -Because "the failure must name the missing '$name' section"
        }
    }

    It 'rejects a brief missing a single required section' {
        $result = Invoke-FVPlanValidate -CommentText (& $script:NewBriefPlan -OmitSections @('6'))

        $structural = & $script:GetCheck $result 'PlanStructuralCoverage'
        $structural.Passed | Should -BeFalse -Because 'a partial brief is not a brief'
        $structural.Detail.Contains('Evidence obligations') | Should -BeTrue
    }

    It 'still rejects a plan that is neither brief, spine-bearing, nor a declared variant' {
        $plan = @'
<!-- plan-issue-999 -->

---
status: pending
priority: p2
issue_id: 999
created: 2026-07-28
ce_gate: true
---

## Plan: An undeclared spine-less plan

## 1. Problem and observed evidence

Prose.
'@
        $result = Invoke-FVPlanValidate -CommentText $plan

        $structural = & $script:GetCheck $result 'PlanStructuralCoverage'
        $structural.Passed | Should -BeFalse
        $structural.Detail.Contains('Missing frame-spine block.') | Should -BeTrue -Because 'the pre-existing rejection path is unchanged'
    }

    It 'rejects a brief that also carries a frame-spine block as ambiguous' {
        $spine = @'
<!-- frame-spine
spine_schema_version: 2
generated_at: "2026-07-28T00:00:00Z"
coverage:
  implement-code: [s1]
-->
'@
        $result = Invoke-FVPlanValidate -CommentText (& $script:NewBriefPlan -ExtraBody $spine)

        $structural = & $script:GetCheck $result 'PlanStructuralCoverage'
        $structural.Passed | Should -BeFalse
        $structural.Detail.Contains('Ambiguous plan') | Should -BeTrue
        $structural.Detail.Contains('brief') | Should -BeTrue
    }

    It 'rejects a brief that also carries a goal-contract block as ambiguous' {
        $contract = @'
<!-- goal-contract
schema_version: 1
issue: 941
-->
'@
        $result = Invoke-FVPlanValidate -CommentText (& $script:NewBriefPlan -ExtraBody $contract)

        $structural = & $script:GetCheck $result 'PlanStructuralCoverage'
        $structural.Passed | Should -BeFalse
        $structural.Detail.Contains('Ambiguous plan') | Should -BeTrue
    }

    It 'does not classify a plan whose prose merely quotes the brief token' {
        # A plan that mentions `plan-variant: brief` in prose (not in
        # frontmatter) must not be routed to the brief branch — the same
        # false-positive class 872-D5 guarded for the goal-contract token.
        #
        # The fixture is a plan that VALIDATES CLEAN and the assertion is on
        # ExitCode, not on the absence of a substring. The original form used a
        # spine with no matching slice anchors, so it failed with 'Invalid
        # canonical frame-spine block' and passed only because that string
        # happens not to contain the substring — it never reached the
        # discrimination it claims to guard (#947 review, M14).
        $plan = @'
<!-- plan-issue-998 -->

---
status: pending
priority: p2
issue_id: 998
created: 2026-07-28
ce_gate: true
spine-omitted: plan-too-small
---

## Plan: A small plan documenting the brief

A chunk plan declares `plan-variant: brief` in its frontmatter.
'@
        $result = Invoke-FVPlanValidate -CommentText $plan

        $structural = & $script:GetCheck $result 'PlanStructuralCoverage'
        $structural.Passed | Should -BeTrue -Because "a quoted token must leave an otherwise-valid plan valid: $($structural.Detail)"
        $result.ExitCode | Should -Be 0
        $structural.Detail | Should -Not -BeLike '*declares plan-variant: brief*'
        (Get-FSCPlanVariant -CommentBody $plan) | Should -BeNullOrEmpty
    }

    It 'rejects a document whose six headings appear only inside a fenced example' {
        # The wrong answer here is a silent PASS, so markdown-blindness is not an
        # acceptable carve-out the way it is for Get-GCContractBlock's loud fail.
        $fenced = @(
            '```markdown',
            '## 1. Problem and observed evidence',
            '## 2. Epistemic map',
            '## 3. Acceptance criteria',
            '## 4. Falsifiers',
            '## 5. Context inventory',
            '## 6. Evidence obligations',
            '```',
            '',
            'That is all. This plan says nothing.'
        ) -join "`n"

        $result = Invoke-FVPlanValidate -CommentText (& $script:NewBriefPlan -OmitSections @('1', '2', '3', '4', '5', '6') -ExtraBody $fenced)

        $structural = & $script:GetCheck $result 'PlanStructuralCoverage'
        $structural.Passed | Should -BeFalse -Because 'quoting the shape is not carrying the shape'
        $structural.Detail.Contains('Problem and observed evidence') | Should -BeTrue
    }

    It 'rejects a document whose six headings appear only inside an HTML comment' {
        $commented = @(
            '<!--',
            '## 1. Problem and observed evidence',
            '## 2. Epistemic map',
            '## 3. Acceptance criteria',
            '## 4. Falsifiers',
            '## 5. Context inventory',
            '## 6. Evidence obligations',
            '-->'
        ) -join "`n"

        $result = Invoke-FVPlanValidate -CommentText (& $script:NewBriefPlan -OmitSections @('1', '2', '3', '4', '5', '6') -ExtraBody $commented)

        $structural = & $script:GetCheck $result 'PlanStructuralCoverage'
        $structural.Passed | Should -BeFalse -Because 'a commented-out heading is not a heading the document carries'
    }

    It 'does not let a bare ## line pair with a following line to satisfy a section' {
        # `\s` matches `\n`; `[ \t]` does not. Same rule as frame-spine-core's
        # block reader (#878 s6).
        $bare = @(
            '##',
            '1. Problem and observed evidence',
            '##',
            '2. Epistemic map'
        ) -join "`n"

        $result = Invoke-FVPlanValidate -CommentText (& $script:NewBriefPlan -OmitSections @('1', '2') -ExtraBody $bare)

        $structural = & $script:GetCheck $result 'PlanStructuralCoverage'
        $structural.Passed | Should -BeFalse
        $structural.Detail.Contains('Problem and observed evidence') | Should -BeTrue -Because 'a bare ## and an unrelated next line is not a heading'
    }

    It 'accepts a legitimate brief that also quotes the six-section template' {
        # The complement of the fenced-only case: stripping fences must not cost
        # a real brief its own sections.
        $quoted = @(
            'For reference, the required shape is:',
            '',
            '```markdown',
            '## 1. Problem and observed evidence',
            '## 4. Falsifiers',
            '```'
        ) -join "`n"

        $result = Invoke-FVPlanValidate -CommentText (& $script:NewBriefPlan -ExtraBody $quoted)

        $structural = & $script:GetCheck $result 'PlanStructuralCoverage'
        $structural.Passed | Should -BeTrue -Because "the real headings are still present: $($structural.Detail)"
    }

    It 'rejects a brief carrying a required section more than once' {
        $result = Invoke-FVPlanValidate -CommentText (& $script:NewBriefPlan -ExtraBody '## 4. Falsifiers — a second, conflicting copy')

        $structural = & $script:GetCheck $result 'PlanStructuralCoverage'
        $structural.Passed | Should -BeFalse -Because 'A3 pins falsifiers to the fourth section by number; two of them leaves the container undefined'
        $structural.Detail.Contains('2 times') | Should -BeTrue
    }

    It 'rejects a frontmatter declaring plan-variant twice, in either order' {
        foreach ($pair in @(@('brief', 'goal-contract'), @('goal-contract', 'brief'))) {
            $fm = "status: pending`nissue_id: 941`nplan-variant: $($pair[0])`nplan-variant: $($pair[1])"
            $result = Invoke-FVPlanValidate -CommentText (& $script:NewBriefPlan -Frontmatter $fm)

            $structural = & $script:GetCheck $result 'PlanStructuralCoverage'
            $structural.Passed | Should -BeFalse -Because "declaring both must not be classified by line order ($($pair -join ' then '))"
            $structural.Detail.Contains('declares plan-variant 2 times') | Should -BeTrue
        }
    }

    It 'rejects a brief carrying two real goal-contract blocks rather than reading the ambiguity as absence' {
        # Get-GCContractBlock returns $null for both "none" and "2+", so a
        # presence check on its result fails OPEN on the ambiguous case.
        $twoBlocks = @(
            '<!-- goal-contract',
            'schema_version: 1',
            'issue: 941',
            '-->',
            '',
            '<!-- goal-contract',
            'schema_version: 1',
            'issue: 941',
            '-->'
        ) -join "`n"

        $result = Invoke-FVPlanValidate -CommentText (& $script:NewBriefPlan -ExtraBody $twoBlocks)

        $structural = & $script:GetCheck $result 'PlanStructuralCoverage'
        $structural.Passed | Should -BeFalse
        $structural.Detail.Contains('2 <!-- goal-contract --> block(s)') | Should -BeTrue
    }

    It 'accepts a brief that quotes a goal-contract block inside a fenced example' {
        # #942 retires the goal-contract harness, so its own brief is near-certain
        # to quote one as evidence. A fence-blind presence check rejects it.
        $fencedContract = @(
            'The block this chunk retires looks like:',
            '',
            '```text',
            '<!-- goal-contract',
            'schema_version: 1',
            'issue: 942',
            '-->',
            '```'
        ) -join "`n"

        $result = Invoke-FVPlanValidate -CommentText (& $script:NewBriefPlan -ExtraBody $fencedContract)

        $structural = & $script:GetCheck $result 'PlanStructuralCoverage'
        $structural.Passed | Should -BeTrue -Because "a fenced documentation example is not a real contract block: $($structural.Detail)"
    }

    It 'rejects a brief carrying frame-slice blocks that nothing would ever walk' {
        $slice = @(
            '<!-- frame-slice',
            'step_id: s1',
            'provides: [implement-code]',
            'adapter: skills/implementation-discipline/adapters/implement-code-adapter.md',
            'ac-refs: [AC1]',
            '-->'
        ) -join "`n"

        $result = Invoke-FVPlanValidate -CommentText (& $script:NewBriefPlan -ExtraBody $slice)

        $structural = & $script:GetCheck $result 'PlanStructuralCoverage'
        $structural.Passed | Should -BeFalse -Because 'a brief is outside Spine-Runner dispatch, so accepted slices are orphaned'
        $structural.Detail.Contains('frame-slice block(s)') | Should -BeTrue
    }

    It 'names an unrecognized variant instead of reporting a missing frame-spine block' {
        $result = Invoke-FVPlanValidate -CommentText (& $script:NewBriefPlan -Frontmatter "status: pending`nplan-variant: breif")

        $structural = & $script:GetCheck $result 'PlanStructuralCoverage'
        $structural.Passed | Should -BeFalse
        $structural.Detail.Contains("unrecognized plan-variant 'breif'") | Should -BeTrue -Because 'a one-letter typo must not send the author down the add-a-spine repair path'
        $structural.Detail.Contains('Missing frame-spine block.') | Should -BeFalse
    }

    It 'validates a brief whose line endings are CR-only' {
        $plan = (& $script:NewBriefPlan) -replace "`n", "`r"

        $result = Invoke-FVPlanValidate -CommentText $plan

        $structural = & $script:GetCheck $result 'PlanStructuralCoverage'
        $structural.Passed | Should -BeTrue -Because "the variant reader normalizes, so the section reader must too: $($structural.Detail)"
    }

    It 'validates a brief whose line endings are CRLF' {
        $plan = (& $script:NewBriefPlan) -replace "`n", "`r`n"

        $result = Invoke-FVPlanValidate -CommentText $plan

        $structural = & $script:GetCheck $result 'PlanStructuralCoverage'
        $structural.Passed | Should -BeTrue -Because "CRLF is the common GitHub body shape: $($structural.Detail)"
    }

    It 'leaves the goal-contract variant rejection path unchanged' {
        $plan = @'
<!-- plan-issue-997 -->

---
status: pending
priority: p2
issue_id: 997
created: 2026-07-28
ce_gate: true
plan-variant: goal-contract
---

## Plan: A goal-contract plan with no contract block
'@
        $result = Invoke-FVPlanValidate -CommentText $plan

        $structural = & $script:GetCheck $result 'PlanStructuralCoverage'
        $structural.Passed | Should -BeFalse
        $structural.Detail.Contains('plan-variant: goal-contract') | Should -BeTrue
    }
}

Describe 'Brief plan variant — the required-section contract' -Tag 'unit' {

    It 'pins the required-section list to the doctrine, number and name together' {
        # The number<->name pairing is load-bearing beyond the heading: A3 in
        # Documents/Design/chunked-delivery.md names "the brief's fourth
        # section" as the container falsifiers reach the executor in, so a
        # renumber falsifies a doctrine sentence. Asserted here so drift in the
        # constant is caught by an independent expectation rather than
        # accepted silently.
        $expected = @(
            @{ Number = 1; Name = 'Problem and observed evidence' }
            @{ Number = 2; Name = 'Epistemic map' }
            @{ Number = 3; Name = 'Acceptance criteria' }
            @{ Number = 4; Name = 'Falsifiers' }
            @{ Number = 5; Name = 'Context inventory' }
            @{ Number = 6; Name = 'Evidence obligations' }
        )

        $actual = @($script:FVBriefRequiredSections)
        $actual.Count | Should -Be $expected.Count

        for ($i = 0; $i -lt $expected.Count; $i++) {
            $actual[$i].Number | Should -Be $expected[$i].Number
            $actual[$i].Name | Should -BeExactly $expected[$i].Name
        }

        ($actual | Where-Object { $_.Number -eq 4 }).Name | Should -BeExactly 'Falsifiers' `
            -Because "chunked-delivery.md's A3 names the brief's FOURTH section as the falsifier container"
    }

    It 'keeps the doctrine sentence and the constant in agreement about section four' {
        $doctrine = & $script:ReadRepoFile 'Documents/Design/chunked-delivery.md'
        $doctrine.Contains("brief's fourth section") | Should -BeTrue
        ($script:FVBriefRequiredSections | Where-Object { $_.Number -eq 4 }).Name | Should -BeExactly 'Falsifiers'
    }
}

Describe 'Brief plan variant — the shared variant reader' -Tag 'unit' {

    It 'reads the declared variant from frontmatter' {
        (Get-FSCPlanVariant -CommentBody (& $script:NewBriefPlan)) | Should -BeExactly 'brief'
    }

    It 'reads quoted forms' {
        foreach ($form in @('"brief"', "'brief'")) {
            $plan = & $script:NewBriefPlan -Frontmatter "status: pending`nplan-variant: $form"
            (Get-FSCPlanVariant -CommentBody $plan) | Should -BeExactly 'brief' -Because "the $form form must read the same"
        }
    }

    It 'does not read a variant out of prose below the frontmatter' {
        $plan = @'
<!-- plan-issue-996 -->

---
status: pending
---

A chunk plan declares plan-variant: brief in its frontmatter.
'@
        (Get-FSCPlanVariant -CommentBody $plan) | Should -BeNullOrEmpty
    }

    It 'reports no declaration for an unterminated frontmatter region' {
        $plan = "<!-- plan-issue-995 -->`n`n---`nstatus: pending`n`n## Plan: no closing fence`n`nplan-variant: brief"
        (Get-FSCPlanVariant -CommentBody $plan) | Should -BeNullOrEmpty
    }

    It 'reports no declaration for an empty or absent body' {
        (Get-FSCPlanVariant -CommentBody '') | Should -BeNullOrEmpty
        (Get-FSCPlanVariant -CommentBody $null) | Should -BeNullOrEmpty
    }

    It 'does not read a commented-out frontmatter block as a live declaration' {
        # The skip loop must track comment CLOSURE, not just the opening
        # delimiter, or it walks through a commented-out block into the real
        # frontmatter having already read the dead one.
        $plan = @'
<!-- plan-issue-994 -->
<!--
---
plan-variant: brief
---
-->

---
status: pending
issue_id: 994
spine-omitted: plan-too-small
---

## Plan: An ordinary small plan
'@
        (Get-FSCPlanVariant -CommentBody $plan) | Should -BeNullOrEmpty -Because 'a commented-out declaration is inert'

        # And the plan it belongs to still validates as what it actually is.
        $result = Invoke-FVPlanValidate -CommentText $plan
        $structural = & $script:GetCheck $result 'PlanStructuralCoverage'
        $structural.Passed | Should -BeTrue -Because "a lawful spine-omitted plan must not be hard-rejected with fabricated brief violations: $($structural.Detail)"
    }

    It 'returns every declaration so a caller can reject the arity' {
        $fm = "status: pending`nplan-variant: brief`nplan-variant: goal-contract"
        $declarations = @(Get-FSCPlanVariantDeclaration -CommentBody (& $script:NewBriefPlan -Frontmatter $fm))

        $declarations.Count | Should -Be 2
        $declarations[0] | Should -BeExactly 'brief'
        $declarations[1] | Should -BeExactly 'goal-contract'
    }
}

Describe 'Brief plan variant — consuming surfaces' -Tag 'unit' {

    It 'the spine renderer names the brief instead of falling through to a misleading message' {
        . (Join-Path $script:RepoRoot '.github/scripts/orchestra-spine.ps1')

        $body = & $script:NewBriefPlan
        $commentsJson = (ConvertTo-Json -Depth 6 -InputObject @(
                [pscustomobject]@{ id = 1; body = $body; created_at = '2026-07-28T00:00:00Z'; updated_at = '2026-07-28T00:00:00Z' }
            ))

        $rendered = [string](Invoke-OrchestraSpineRender -IssueNumber 941 -CommentsJson $commentsJson)

        $rendered | Should -Match '(?i)brief' -Because 'a brief must render the shape-aware message'
        $rendered | Should -Not -Match 'legacy-plan-shape' -Because 'a brief is not a legacy plan'
        $rendered | Should -Not -Match 'plan has no spine — see comment' -Because 'the plan-too-small message describes a size, not this shape'
    }

    It 'the spine renderer reports a brief+spine plan as ambiguous rather than as a normal brief' {
        . (Join-Path $script:RepoRoot '.github/scripts/orchestra-spine.ps1')

        $spine = @(
            '<!-- frame-spine',
            'spine_schema_version: 1',
            'generated_at: 2026-05-05T11:00:00Z',
            'coverage: complete',
            'ports:',
            '  implement-test: [s11]',
            '-->'
        ) -join "`n"
        $body = & $script:NewBriefPlan -ExtraBody $spine
        $commentsJson = (ConvertTo-Json -Depth 6 -InputObject @(
                [pscustomobject]@{ id = 1; body = $body; created_at = '2026-07-28T00:00:00Z'; updated_at = '2026-07-28T00:00:00Z' }
            ))

        $rendered = [string](Invoke-OrchestraSpineRender -IssueNumber 941 -CommentsJson $commentsJson)

        $rendered | Should -Match '(?i)ambiguous' -Because 'the validator fails this plan; the renderer must not present it as a normal brief'
        $rendered | Should -Not -Match 'no spine by design' -Because 'a spine block is present, so that statement would be false'
    }

    It 'the planner does not tell a brief author to emit the plan-too-small size token' {
        $content = & $script:ReadRepoFile 'agents/Issue-Planner.agent.md'

        $content.Contains('A `plan-variant: brief` plan does NOT emit `spine-omitted: plan-too-small`') | Should -BeTrue `
            -Because 'a brief has zero implementation steps, so the fewer-than-3 rule would otherwise apply and contradict the brief contract'
    }

    It 'the planner spine-append escape covers the brief, not only the goal-contract variant' {
        $content = & $script:ReadRepoFile 'agents/Issue-Planner.agent.md'

        $content | Should -Match '(?s)plan-variant: brief.{0,600}(skip this entire append|no `<!-- frame-spine -->` block)' `
            -Because 'appending a spine to a brief produces a plan the validator rejects as ambiguous'
        $content.Contains('neither `plan-variant: goal-contract` nor `plan-variant: brief`') | Should -BeTrue `
            -Because 'the append rule must not treat a brief as an ordinary spine-bearing plan'
    }

    It 'Spine-Runner declares itself ineligible for a brief' {
        $content = & $script:ReadRepoFile 'agents/Spine-Runner.agent.md'
        $content.Contains('This plan uses the brief variant, which has no frame-spine by design') | Should -BeTrue
    }

    It 'the frame-spine lookup skill scopes the brief out' {
        $content = & $script:ReadRepoFile 'skills/frame-spine-lookup/SKILL.md'
        $content.Contains('plan-variant: brief') | Should -BeTrue
    }

    It 'Code-Conductor keeps the goal-contract halt and routes a brief to the surviving pipeline' {
        $content = & $script:ReadRepoFile 'agents/Code-Conductor.agent.md'

        $content.Contains('which requires the not-yet-built #874 goal-run harness') | Should -BeTrue `
            -Because 'the goal-contract guard is not removed on the grounds a later chunk retires it (#936 D3)'
        $content | Should -Match '(?s)`plan-variant: brief` plan.{0,300}dispatch the full plan' `
            -Because 'the surviving orchestration path is the revocation lane for a brief'
    }
}

Describe 'Brief plan variant — authoring rule' -Tag 'unit' {

    It 'plan-authoring admits the brief as a lawful shape rather than merely not forbidding it' {
        $content = & $script:ReadRepoFile 'skills/plan-authoring/SKILL.md'

        $content.Contains('plan-variant: brief') | Should -BeTrue -Because 'the authoring rule must name the brief token'
        $content | Should -Match '(?m)^###\s+Brief plan variant\s*$' -Because 'the brief needs its own authoring contract section'
    }

    It 'plan-authoring names every section a brief must carry' {
        $content = & $script:ReadRepoFile 'skills/plan-authoring/SKILL.md'

        foreach ($name in @('Problem and observed evidence', 'Epistemic map', 'Acceptance criteria', 'Falsifiers', 'Context inventory', 'Evidence obligations')) {
            $content.Contains($name) | Should -BeTrue -Because "the brief's required '$name' section must be documented where a planner authors it"
        }
    }

    It 'the spine-omission rule carves the brief out by shape, not by size' {
        $content = & $script:ReadRepoFile 'skills/plan-authoring/SKILL.md'

        $content | Should -Match '(?s)Spine and Slice Discipline.{0,4000}plan-variant: brief' `
            -Because 'a brief must not need the plan-too-small size carve-out to be lawful'
    }
}

Describe 'Brief plan variant — conformance check' -Tag 'unit' {

    It 'declares the five properties: four mechanical (#936 D5) plus the vacuity reading (#957 D2)' {
        $content = & $script:ReadRepoFile 'skills/plan-authoring/SKILL.md'

        $content | Should -Match '(?m)^####\s+Brief conformance check\s*$'
        $section = ($content -split '(?m)^####\s+Brief conformance check\s*$')[1]
        $section | Should -Not -BeNullOrEmpty

        # Bound to the end of the conformance-check section so a match elsewhere
        # in the 900-line skill cannot satisfy this.
        $section = ($section -split '(?m)^##')[0]

        $section.Contains('artifact') | Should -BeTrue -Because 'property 1: artifact pinning'
        ($section.Contains('source-read') -and $section.Contains('sample-inferred')) | Should -BeTrue -Because 'property 2: provenance marking'
        $section.Contains('proof standard') | Should -BeTrue -Because 'property 3: evidence obligations present'
        $section.Contains('floor') | Should -BeTrue -Because 'property 4: suite floor satisfiable against the launch baseline'
        $section.Contains('Is there a reading of the criteria under which every one passes and no work happens?') | Should -BeTrue `
            -Because 'property 5: the vacuity question, verbatim as #957 D2 fixed it'
    }

    It 'makes property 5 an act of construction, so a bare "no" cannot discharge it' {
        # The whole tooth is the READING. A property-5 phrased as a bare
        # question is satisfied by "no reading exists" written without looking
        # -- which is exactly what a reviewer who never looked would also
        # write, so the emission would carry no information (#973 AC1).
        $content = & $script:ReadRepoFile 'skills/plan-authoring/SKILL.md'
        $section = ($content -split '(?m)^####\s+Brief conformance check\s*$')[1]
        $section = ($section -split '(?m)^##')[0]

        $section.Contains('Answering is an act of construction, not of assertion.') | Should -BeTrue `
            -Because 'the expected act must be constructing the candidate reading, not answering the question'
        $section.Contains('does **not** discharge this property') | Should -BeTrue `
            -Because 'the bare-no answer must be named nonconforming, or the property lands vacuously'
    }

    It 'no longer frames the check as covering only near-mechanical text properties' {
        # Property 5 appended while the framing sentence one paragraph above
        # still said "the four near-mechanical properties" would leave the
        # check disagreeing with itself about what it is (#973 falsifier 2).
        $content = & $script:ReadRepoFile 'skills/plan-authoring/SKILL.md'
        $section = ($content -split '(?m)^####\s+Brief conformance check\s*$')[1]
        $section = ($section -split '(?m)^##')[0]

        $section.Contains('It covers the four near-mechanical properties #936 D5 named') | Should -BeFalse `
            -Because 'the framing sentence must admit the reading-property alongside the four'
        $section.Contains('property 5 needs a reading of what the criteria mean *together*') | Should -BeTrue `
            -Because 'the closing reading-enumeration goes stale on landing unless it grows with the new property'
    }

    It 'the conformance check is reachable from every point that dispatches a brief review' {
        # #981 review, M22: this It and the routing-call reachability It were
        # both named 'is reachable from every point that dispatches a brief
        # review'. run-pester-sharded reports failures as `[-] {It name}` with
        # no Describe path, so a red run could not tell the two apart.
        foreach ($path in @('commands/plan.md', 'skills/plan-authoring/SKILL.md', 'agents/Issue-Planner.agent.md')) {
            $content = & $script:ReadRepoFile $path
            $content.Contains('Brief conformance check') | Should -BeTrue -Because "$path must let a reviewer reach the conformance check from where they work"
        }
    }
}

Describe 'Brief review teeth — the routing call as a review target (#973)' -Tag 'unit' {

    It 'the routing-call target is pointed at from every point that dispatches a brief review' {
        # #981 review, M19: the first version of this test asserted the bare
        # section NAME over all three files. In `plan-authoring` that literal IS
        # the section's own `####` heading, so the assertion could not fail while
        # the section existed — deleting BOTH dispatch-point pointers left it
        # green (verified by mutation). Every pointer is backticked and the
        # heading is not, so asserting the backticked form separates the two.
        foreach ($path in @('commands/plan.md', 'skills/plan-authoring/SKILL.md', 'agents/Issue-Planner.agent.md')) {
            $content = & $script:ReadRepoFile $path
            $content.Contains('`#### The routing call as a review target`') | Should -BeTrue `
                -Because "$path dispatches a brief review, so it must POINT AT the routing-call target, not merely contain its heading"
        }

        # `plan-authoring` owns the section, so it must carry the heading AND at
        # least one pointer to it from a dispatch point (§ Keep the Review
        # Pipeline Explicit and § Stress-Test Preparation both point).
        $planAuthoring = & $script:ReadRepoFile 'skills/plan-authoring/SKILL.md'
        ([regex]::Matches($planAuthoring, [regex]::Escape('`#### The routing call as a review target`')).Count) |
            Should -BeGreaterOrEqual 2 `
            -Because 'both dispatch points in the owning skill must reach the section, not just one'
    }

    It 'defines all four source-(b) outcome arms, including novel-verdict and verdict-absent as failures' {
        $content = & $script:ReadRepoFile 'skills/plan-authoring/SKILL.md'
        $section = ($content -split '(?m)^####\s+The routing call as a review target\s*$')[1]
        $section | Should -Not -BeNullOrEmpty
        $section = ($section -split '(?m)^##')[0]

        $section.Contains('Present, routine, and consistent with the map') | Should -BeTrue -Because 'arm 1'
        $section.Contains('Present, routine, but inconsistent with the map') | Should -BeTrue -Because 'arm 2'
        $section.Contains('Present but novel') | Should -BeTrue `
            -Because 'arm 3 (#981 review, M3): a recorded NOVEL verdict is the same lawfulness failure as an absent one; without this arm it passes as "checked and consistent"'
        $section.Contains('not lawful under source (b)') | Should -BeTrue `
            -Because 'arm 4: Amendment 10 makes a missing verdict a review failure, not a gap to note'
    }

    It 'states what a routing-call review failure means instead of leaving it to inference' {
        # #981 review, M4: "review failure" was the strongest word in the
        # section and the only one with no defined effect — three surfaces
        # declare this pipeline non-blocking, so an undefined failure verdict is
        # dismissible under the ordinary triad. The fix states the required
        # action AND states honestly that nothing mechanical enforces it.
        $content = & $script:ReadRepoFile 'skills/plan-authoring/SKILL.md'
        $section = ($content -split '(?m)^####\s+The routing call as a review target\s*$')[1]
        $section = ($section -split '(?m)^##')[0]

        $section.Contains('corrected before the brief is dispatched or run') | Should -BeTrue `
            -Because 'the failure verdict must name its required action, the way the conformance check does'
        $section.Contains('nothing mechanical enforces that') | Should -BeTrue `
            -Because 'claiming an unenforced consequence is the overclaim class this chunk exists to remove'
    }

    It 'says naming the classification evidence is not verifying it' {
        # #981 review, M5: the section claimed a misclassified source "cannot
        # produce a lawful-looking result", which naming alone does not buy.
        $content = & $script:ReadRepoFile 'skills/plan-authoring/SKILL.md'
        $section = ($content -split '(?m)^####\s+The routing call as a review target\s*$')[1]
        $section = ($section -split '(?m)^##')[0]

        $section.Contains('cannot produce a lawful-looking result') | Should -BeFalse `
            -Because 'naming the evidence does not re-derive the parent link, so the absolute claim was false'
        $section.Contains('naming is not verifying') | Should -BeTrue `
            -Because 'the limit must be stated at the site rather than implied'
    }

    It 'pins the source-(a) n/a rationale and forbids the family-false one' {
        # "no beat 2 ran" is FALSE for a chunk of a novel-arm parent, where
        # beat 2 did run and its verdict rides the parent design marker
        # (open-for-work.md, § The two outputs). Instructing that rationale
        # would make every such n/a a false statement (#973 AC4).
        $content = & $script:ReadRepoFile 'skills/plan-authoring/SKILL.md'
        $section = ($content -split '(?m)^####\s+The routing call as a review target\s*$')[1]
        $section = ($section -split '(?m)^##')[0]

        $section.Contains('carries no routing verdict of its own') | Should -BeTrue `
            -Because 'the n/a basis must be the one true across both source-(a) families'
        $section.Contains('Do not write "no beat 2 ran"') | Should -BeTrue `
            -Because 'the family-false rationale must be named and forbidden, not merely not-recommended'
        $section.Contains('emission, not a skip') | Should -BeTrue `
            -Because 'a skippable n/a is today behaviour with extra words'
    }
}

Describe 'Brief review teeth — required cold-read vacuity question (#973)' -Tag 'unit' {

    BeforeAll {
        # #981 review, M11: these assertions originally ran against the WHOLE
        # 900-line skill, unlike their section-bounded siblings, so the text
        # could migrate out of § Convergence Filter and still satisfy them.
        $script:ConvergenceSection = {
            $content = & $script:ReadRepoFile 'skills/design-exploration/SKILL.md'
            $section = ($content -split '(?m)^###\s+Convergence Filter\s*$')[1]
            if ([string]::IsNullOrWhiteSpace($section)) { throw 'section "### Convergence Filter" not found' }
            return ($section -split '(?m)^###\s')[0]
        }
    }

    It 'the convergence cold read requires the vacuity question on a brief target, verbatim' {
        $section = & $script:ConvergenceSection

        $section.Contains('Is there a reading of the criteria under which every one passes and no work happens?') | Should -BeTrue `
            -Because 'the cold read is the vacuity question''s load-bearing adversarial instance (#957 D2)'
        $section.Contains('asked, no surviving reading') | Should -BeTrue `
            -Because 'a clean result needs a stated sentence, or silence stays ambiguous between examined and never-examined'
        $section.Contains('nonconforming run, not a clean one') | Should -BeTrue `
            -Because 'a record with no vacuity sentence must be identifiable as nonconforming'
    }

    It 'conditions the requirement on the target being a brief, not merely claiming the design path is unchanged' {
        # #981 review, M11 (mutation-verified by defense and judge): asserting
        # only the "design-target ... unchanged" sentence left the suite green
        # when the CONDITIONING clause was deleted — which would make the
        # vacuity question unconditional and change every Solution-Designer
        # design review, the exact scope creep #957 P1-F12 declined. Pin the
        # condition itself, not the reassurance about its consequence.
        $section = & $script:ConvergenceSection

        $section.Contains('When the artifact under convergence is a `plan-variant: brief` plan') | Should -BeTrue `
            -Because 'the addendum must be CONDITIONED on the target shape; without this clause it applies to every design review'
        $section.Contains('A design-target convergence pass is behaviourally unchanged') | Should -BeTrue `
            -Because 'the unchanged-design-path promise must be stated as well as structurally true'
    }

    It 'names the carrying surface for the vacuity answer in both polarities' {
        # #981 review, D1 (defense-found, mutation-verified): the
        # carrying-surface sentence was deletable with the suite still green,
        # and it is the sub-property the whole "silence is not clean" claim
        # turns on — a clean answer produces no rulings row, so if it does not
        # land in the summary it lands nowhere.
        $section = & $script:ConvergenceSection
        $section.Contains('summary is the carrying surface') | Should -BeTrue `
            -Because 'without a named landing surface a clean vacuity answer is recorded nowhere'

        $planAuthoring = & $script:ReadRepoFile 'skills/plan-authoring/SKILL.md'
        $planAuthoring.Contains('record the outcome in the persisted `**Plan Stress-Test**` summary') | Should -BeTrue `
            -Because 'the routing-call outcome needs the same named landing surface'
    }

    It 'tells the summary WRITER to carry both emissions, not only the reviewer to produce them' {
        # #981 review, M2: both emissions named the persisted stress-test
        # summary as their carrying surface while the reconciliation step that
        # composes that summary still asked only for judge ruling + maintainer
        # disposition — so the doctrine declared the default output of its own
        # unamended writer step nonconforming.
        $content = & $script:ReadRepoFile 'skills/plan-authoring/SKILL.md'
        $section = ($content -split '(?m)^###\s+Post-Judge Reconciliation\s*$')[1]
        $section | Should -Not -BeNullOrEmpty
        $section = ($section -split '(?m)^###\s')[0]

        $section.Contains('vacuity answer') | Should -BeTrue `
            -Because 'the writer step must ask for the vacuity sentence, or no one composes it'
        $section.Contains('routing-call outcome') | Should -BeTrue `
            -Because 'the writer step must ask for the routing-call outcome for the same reason'
    }

    It 'does not tell a brief-path reader that nothing else in the section is shape-conditioned' {
        # #981 review, M8: the sentence was falsified by a line the same commit
        # wrote, and invited a brief-path reader onward into the design-only
        # `finding_dispositions:` tagging the repo excluded on purpose.
        $section = & $script:ConvergenceSection

        $section.Contains('nothing else in this section is conditioned on the target''s shape') | Should -BeFalse `
            -Because 'the caller-identity sentence and the pass-4 tagging are both shape-conditioned'
        $section.Contains('A brief emits `brief_dispositions:`') | Should -BeTrue `
            -Because 'the brief path must be steered away from the design marker''s schema at the point of exposure'
    }

    It 'scopes the pass-4 finding_dispositions tagging to design targets at the instruction itself' {
        # External review (Codex bot, PR #981): warning a brief-path reader
        # upstream is not enough — a reader arriving directly at the pass-4
        # sentence (by search, or by reading the section in order) still met an
        # unqualified instruction to tag findings into `finding_dispositions:`,
        # the design-completion token whose reuse on a brief renders a
        # permanent false design-challenge gap.
        $section = & $script:ConvergenceSection

        $section.Contains('**On a design target**, cold-read-originated findings') | Should -BeTrue `
            -Because 'the pass-4 instruction must carry its own scope, not rely on a caveat several paragraphs earlier'
        $section.Contains('A brief target does not use this tagging.') | Should -BeTrue `
            -Because 'the brief path needs an explicit exclusion at the point the design token is named'
    }

    It 'both doctrine surfaces name the persisted landing surface for the vacuity answer' {
        # External review (CodeRabbit, PR #981): both doctrine documents
        # required the question and the emitted answer while naming neither the
        # durable artifact nor the producer — so a reader learning the charter
        # from doctrine alone would not know that silence is nonconforming.
        foreach ($path in @('Documents/Design/chunked-delivery.md', 'Documents/Design/open-for-work.md')) {
            $content = & $script:ReadRepoFile $path
            $content.Contains('Plan Stress-Test') | Should -BeTrue `
                -Because "$path states the vacuity requirement, so it must also name where the answer is persisted"
        }
    }

    It 'the required answer has an instructed producer, not only an asker' {
        # A requirement written only into the dispatcher prose has no producer:
        # the shell that PERFORMS the cold read is instructed by its own body,
        # which scoped this dispatch shape to Solution-Designer and was
        # therefore false by omission on the brief path (#973 AC3).
        $content = & $script:ReadRepoFile 'agents/code-review-response.md'

        $content.Contains('When dispatched by Solution-Designer for design-challenge convergence') | Should -BeFalse `
            -Because 'the producer surface must not scope this dispatch shape to the wrong dispatcher'
        $content.Contains('answering that section''s required vacuity question in part (a) is part of the contract') | Should -BeTrue `
            -Because 'the shell performing the cold read must be told to answer, not only the dispatcher told to ask'
    }
}

Describe 'Brief plan variant — review charter' -Tag 'unit' {

    It 'every adapter-selecting dispatch point routes a brief to design-challenge' {
        # Asserts the SELECTION SENTENCES, not word proximity. The original
        # bounded-distance regex stayed true after both selection steps were
        # deleted — two unrelated occurrences satisfied it (#947 review, M13).
        $expected = @{
            'commands/plan.md'                = 'declares `plan-variant: brief` — the brief shape, whichever of its two authority sources it carries (#957 D4) — uses adapter `design-challenge`'
            'skills/plan-authoring/SKILL.md'  = 'declares `plan-variant: brief` selects `skills/adversarial-review/adapters/design-challenge.md`'
        }

        foreach ($path in $expected.Keys) {
            $content = & $script:ReadRepoFile $path
            $content.Contains($expected[$path]) | Should -BeTrue `
                -Because "$path is where the review adapter is actually selected for /plan; deleting the selection rule must turn this red"
        }
    }

    It 'keeps the standard adapter selected for every non-brief plan' {
        # `Contains('standard')` was vacuous: it is satisfied by "standards
        # check", "proof standard", "standard frame-spine plan" — all present on
        # origin/main (#947 review, M13).
        $expected = @{
            'commands/plan.md'               = 'Every other plan shape uses adapter `standard`.'
            'skills/plan-authoring/SKILL.md' = 'Every other plan shape selects `standard` as before.'
        }

        foreach ($path in $expected.Keys) {
            $content = & $script:ReadRepoFile $path
            $content.Contains($expected[$path]) | Should -BeTrue `
                -Because "$path must keep an explicit fall-through to ``standard`` for spine-bearing plans"
        }
    }

    It 'leaves code review''s standard adapter pass declaration untouched' {
        $content = & $script:ReadRepoFile 'skills/adversarial-review/adapters/standard.md'

        $content | Should -Match '(?m)^\s*prosecution-passes:\s*\[1, 2, 3, 4, 5\]\s*$' `
            -Because 'the standard adapter is the code-review adapter; re-aiming plan review must not relax it'
        $content | Should -Match 'changeset\.totalLines >= 200' `
            -Because 'the standard adapter predicate stays keyed on changeset size'
    }

    It 'leaves no unconditional standard-adapter dispatch in the planner body' {
        # A fourth adapter-selection site the DA4 enumeration missed — the
        # ordering rule in the planner body said "following the `standard`
        # adapter" unconditionally, contradicting the brief selection rule
        # earlier in the same file (#947 external review).
        $content = & $script:ReadRepoFile 'agents/Issue-Planner.agent.md'

        $content.Contains('following the `standard` adapter,') | Should -BeFalse `
            -Because 'an unconditional standard dispatch contradicts the shape-based selection rule'
        $content.Contains('the adapter selected by the plan''s shape') | Should -BeTrue `
            -Because 'the ordering rule must defer to the selection step rather than naming one adapter'
    }

    It 'the planner charter no longer prescribes the five-pass panel for a brief' {
        # `Contains('brief')` is TRUE on origin/main ("standard brief", "context
        # brief"), so it never guarded anything (#947 review, M13).
        $content = & $script:ReadRepoFile 'agents/Issue-Planner.agent.md'

        $content.Contains('Chunk sub-issues of a designed parent are authored as a brief instead') | Should -BeTrue `
            -Because 'the planner charter must name the brief shape as the chunk-plan artifact'
        $content.Contains('the prosecution-only `design-challenge` adapter') | Should -BeTrue `
            -Because 'the planner charter must route a brief to the design-challenge shape'
        $content.Contains('not the five-pass panel') | Should -BeTrue `
            -Because 'the charter must say what stops applying, not only what starts'
    }
}

Describe 'Brief plan variant — doctrine migration' -Tag 'unit' {

    BeforeAll {
        # The interim-migration-note section deliberately quotes retired
        # vocabulary; the completion check excludes it by design (#939).
        $script:StripInterimNote = {
            param([string]$Text)
            return ($Text -replace '(?s)<!--\s*interim-migration-note:begin\s*-->.*?<!--\s*interim-migration-note:end\s*-->', '')
        }
    }

    It 'CLAUDE.md Bound-2 mirror names the brief and describes what a brief actually states' {
        # The first draft swapped the noun but kept the goal-contract's field
        # list — "targets, invariants, evidence obligations, halt conditions,
        # and budget" — none of which are brief sections beyond the third.
        # AC5 requires the sentence to READ TRUE, not merely to name the brief
        # (#947 external review).
        $content = & $script:ReadRepoFile 'CLAUDE.md'

        $content.Contains("each chunk's **brief** states") | Should -BeTrue
        $content.Contains("each chunk's **goal-contract** states") | Should -BeFalse
        $content.Contains('halt conditions, and budget, then stops') | Should -BeFalse `
            -Because 'the brief contract requires no halt-conditions or budget section; that list described the goal-contract'
        $content.Contains('evidence obligations') | Should -BeTrue -Because 'A5 cites this sentence as proof the doctrine already required evidence obligations'
    }

    It 'chunked-delivery Bound 2 describes the brief''s actual contract, not the goal-contract field list' {
        $content = & $script:ReadRepoFile 'Documents/Design/chunked-delivery.md'
        $body = & $script:StripInterimNote $content

        $body.Contains('halt conditions, and a budget') | Should -BeFalse `
            -Because 'Bound 2 must describe what a brief hands the executor, not what a goal-contract did'
        $body.Contains('evidence obligations') | Should -BeTrue
    }

    It 'CLAUDE.md operating rule names the brief' {
        $content = & $script:ReadRepoFile 'CLAUDE.md'
        $content.Contains('one chunk = one sub-issue = one brief') | Should -BeTrue
        $content.Contains('one chunk = one sub-issue = one goal-contract') | Should -BeFalse
    }

    It 'CLAUDE.md panel-depth clause reflects the re-aimed charter' {
        $content = & $script:ReadRepoFile 'CLAUDE.md'
        $content.Contains('chunk-plan panel depth relaxes only via phase-containment-ledger evidence') | Should -BeFalse `
            -Because 'the chunk-plan panel rule stops applying to a brief rather than relaxing'
        $content.Contains('design-challenge') | Should -BeTrue
    }

    It 'chunked-delivery Bound 2 names the brief' {
        $content = & $script:ReadRepoFile 'Documents/Design/chunked-delivery.md'
        $body = & $script:StripInterimNote $content
        $body | Should -Match '(?m)^\*\*Bound 2.{0,400}brief'
        $body.Contains('Each chunk''s goal-contract plan') | Should -BeFalse
    }

    It 'chunked-delivery operating rules name the brief' {
        $content = & $script:ReadRepoFile 'Documents/Design/chunked-delivery.md'
        $body = & $script:StripInterimNote $content
        $body.Contains('goal-contract mode') | Should -BeFalse
        $body.Contains("the chunk's brief cites the parent decisions it implements") | Should -BeTrue
    }

    It 'chunked-delivery A3 specialises the container to the brief''s fourth section' {
        $content = & $script:ReadRepoFile 'Documents/Design/chunked-delivery.md'
        $body = & $script:StripInterimNote $content
        $body | Should -Match "(?s)\*\*A3.{0,1200}brief's fourth section"
    }

    It 'chunked-delivery no longer claims nothing enforces A1-A5 at authoring time' {
        # Rationale corrected (#947 review, M23): the VALIDATOR half does not
        # falsify that sentence — a brief with all six sections and an
        # artifact-pinned, unchecked-floor criterion still validates. What
        # falsifies it is that some enforcement now exists at authoring time at
        # all, and the replacing prose is careful to say what it does not reach.
        $content = & $script:ReadRepoFile 'Documents/Design/chunked-delivery.md'
        $body = & $script:StripInterimNote $content
        $body.Contains('a plan can violate any of A1–A5 and still validate') | Should -BeFalse `
            -Because 'the sentence claims nothing enforces A1-A5 at authoring time, which the conformance check falsifies'
        # The reach-claim MOVED with #973, and the pin moved in the same change.
        # Property 5 performs the catch A3 names (targets satisfiable without
        # the fix), so "Neither reaches A1 or A3" became false on landing --
        # the noun-swapped-predicate-left-false class. What replaces it still
        # states a limit (A1, and A3's own delivery-form rule), which is what
        # this pin has always been defending.
        $body.Contains('Neither reaches A1 or A3') | Should -BeFalse `
            -Because 'the reading-property reaches the catch A3 names, so the old reach-claim is now false'
        $body.Contains('What none of it reaches: A1, and the rule A3 itself states.') | Should -BeTrue `
            -Because 'the replacement must state what the new enforcement does NOT reach, or it overclaims in the other direction'
    }

    It 'the migration table no longer schedules rows this chunk has discharged' {
        $content = & $script:ReadRepoFile 'Documents/Design/chunked-delivery.md'
        $content.Contains("the chunk's goal-contract cites the parent decisions it implements") | Should -BeFalse
        $content.Contains('**Panel depth earns its way down.** Chunk plans start with the full adversarial plan review') | Should -BeFalse
    }

    It 'the CLAUDE.md charter mirror enumerates the same charter as chunked-delivery' {
        # #981 review, M12: CLAUDE.md:123 and chunked-delivery.md:26 are a
        # maintained mirror pair, but THIS sentence was pinned on neither side,
        # so #973 updated one and left the other enumerating a two-component
        # charter. CLAUDE.md is the first document every session loads.
        # Deliberately assert the CONCEPTS, not a property count — a count here
        # would mint exactly the drift site falsifier 6 warns about.
        $claudeMd = & $script:ReadRepoFile 'CLAUDE.md'
        $doctrine = & $script:ReadRepoFile 'Documents/Design/chunked-delivery.md'

        foreach ($concept in @('vacuity reading', 'routing-call review target')) {
            $claudeMd.Contains($concept) | Should -BeTrue `
                -Because "the CLAUDE.md charter mirror must name '$concept'; it is the first document every session loads"
            $doctrine.Contains($concept) | Should -BeTrue `
                -Because "the chunked-delivery side of the mirror must name '$concept' too"
        }

        $claudeMd.Contains('the brief conformance check plus the prosecution-only `design-challenge` shape') |
            Should -BeFalse `
            -Because 'the pre-#973 two-component enumeration is stale once the teeth land'
    }

    It 'the migration table still records the rows later chunks own' {
        $content = & $script:ReadRepoFile 'Documents/Design/chunked-delivery.md'
        $content.Contains('#942') | Should -BeTrue
        $content.Contains('#943') | Should -BeTrue
    }
}
