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
         and covers the four mechanical properties #936 D5 named. (#941 AC6)
#>

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
    $script:LibFile = Join-Path $script:RepoRoot '.github/scripts/lib/frame-validate-core.ps1'
    . $script:LibFile

    # A minimally-conforming brief: the six numbered sections the two shipped
    # briefs (#939, #941) both carry, read from those artifacts rather than
    # inferred from one sample.
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

    It 'declares the four mechanical properties #936 D5 named' {
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
    }

    It 'is reachable from every point that dispatches a brief review' {
        foreach ($path in @('commands/plan.md', 'skills/plan-authoring/SKILL.md', 'agents/Issue-Planner.agent.md')) {
            $content = & $script:ReadRepoFile $path
            $content.Contains('Brief conformance check') | Should -BeTrue -Because "$path must let a reviewer reach the conformance check from where they work"
        }
    }
}

Describe 'Brief plan variant — review charter' -Tag 'unit' {

    It 'every adapter-selecting dispatch point routes a brief to design-challenge' {
        # Asserts the SELECTION SENTENCES, not word proximity. The original
        # bounded-distance regex stayed true after both selection steps were
        # deleted — two unrelated occurrences satisfied it (#947 review, M13).
        $expected = @{
            'commands/plan.md'                = 'declares `plan-variant: brief` — the chunk-plan shape — uses adapter `design-challenge`'
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

    It 'CLAUDE.md Bound-2 mirror names the brief, not the goal-contract' {
        $content = & $script:ReadRepoFile 'CLAUDE.md'
        $content | Should -Match "each chunk's \*\*brief\*\* states targets, invariants, evidence obligations, halt conditions, and budget"
        $content.Contains("each chunk's **goal-contract** states") | Should -BeFalse
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
        $body.Contains('Neither reaches A1 or A3') | Should -BeTrue `
            -Because 'the replacement must state what the new enforcement does NOT reach, or it overclaims in the other direction'
    }

    It 'the migration table no longer schedules rows this chunk has discharged' {
        $content = & $script:ReadRepoFile 'Documents/Design/chunked-delivery.md'
        $content.Contains("the chunk's goal-contract cites the parent decisions it implements") | Should -BeFalse
        $content.Contains('**Panel depth earns its way down.** Chunk plans start with the full adversarial plan review') | Should -BeFalse
    }

    It 'the migration table still records the rows later chunks own' {
        $content = & $script:ReadRepoFile 'Documents/Design/chunked-delivery.md'
        $content.Contains('#942') | Should -BeTrue
        $content.Contains('#943') | Should -BeTrue
    }
}
