#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#!
.SYNOPSIS
    The guard that stops a lesson promotion being a silent demotion.

.DESCRIPTION
    A lesson in the private memory store fires unconditionally at session start. Moved into a
    repository file it fires only if someone loads the gating skill AND reaches the lesson inside
    it. With no check, a lesson can be "promoted" into a file nothing loads and the promotion
    books as a success.

    `Documents/Planning/lesson-promotion-manifest.json` records the roster, each lesson's home and
    anchor, and the trigger text that has to reach a reader. This file keeps that manifest and the
    tree honest in BOTH directions:

      forward - every promoted lesson has a lens in a loading surface, a description trigger that
                clears a specificity floor, and a body trigger inside its own named anchor;
      reverse - every file in a receiving references/ directory has a manifest row.

    THE EXPECTED COUNTS AND THE RECEIVING SET LIVE HERE, NOT IN THE MANIFEST. That is the whole
    point of where they sit (PR #1055 review, findings M3, M9, M11): a roster count compared
    against a number in the same file cannot catch an entry removed and the count decremented in
    one edit, and a reverse scan whose population is derived from the manifest cannot catch a
    directory removed from the manifest. Both are pinned below, in a different artifact, and the
    core refuses to run its own weaker fallback silently.

    Structure follows `ci-suite-registration.Tests.ps1`: live-tree assertions against the real
    repository, then induced-failure fixtures built in a temp directory that the working tree is
    never used as, then a positive control without which every induced assertion above would be
    satisfied by a function that returns HasDrift = $true for all inputs.

    RENAME MIGRATION. Renaming a lens heading is a migration, not a regression: update that
    lesson's `anchor` in the manifest in the same commit as the rename. A red naming an anchor you
    just renamed is reporting a manifest row left behind, not a lost lens.
#>

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..')).Path
    . (Join-Path $script:RepoRoot '.github/scripts/lib/lesson-promotion-core.ps1')
    $script:ManifestPath = Join-Path $script:RepoRoot 'Documents/Planning/lesson-promotion-manifest.json'

    # --- The pins that must not live in the artifact under audit. -------------------------------
    # Roster size: parent #1045 Amendment A1 (45 -> 46 after two same-day admissions).
    $script:ExpectedRosterCount = 46
    # Per-chunk promoted share: parent #1045 § Walking-skeleton lens list, as partitioned by A1.
    # Chunk 1 takes 19. Chunk 2 was ASSIGNED 27 and promoted 25: two of its lessons returned a
    # `conflict` verdict against shipped doctrine and, under parent #1045 amendment A4.5, a second
    # contradiction of any kind routes up rather than being resolved in-chunk. Those two stay
    # `pending` against issue #1050 until the parent rules, and their lens sections were removed
    # rather than shipped beside the sentences they contradict. Chunk 3 adds its own row when it
    # lands. An ABSENT key is the quiet escape - the audit iterates only the keys handed to it, so
    # a chunk promoting under a key nobody declared would be counted by nothing.
    $script:ExpectedPromotedByChunk = @{ '1' = 19; '2' = 25 }
    # The skills this promotion effort receives into. A references/ file appearing in any of these
    # needs a manifest row; directories outside the set belong to other skills and predate this
    # manifest, which is not the registry for them.
    $script:ReceivingSkillDirs = @(
        'skills/verification-before-completion'
        'skills/plan-authoring'
        'skills/adversarial-review'
        'skills/terminal-hygiene'
        'skills/safe-operations'
        'skills/implementation-discipline'
        'skills/test-driven-development'
        'skills/design-exploration'
        'skills/agent-memory-compaction'
    )

    $script:Live = Get-LessonPromotionAudit -RepoRoot $script:RepoRoot -ManifestPath $script:ManifestPath `
        -ExpectedRosterCount $script:ExpectedRosterCount `
        -ExpectedPromotedByChunk $script:ExpectedPromotedByChunk `
        -ReceivingSkillDirs $script:ReceivingSkillDirs

    $script:Scratch = Join-Path ([System.IO.Path]::GetTempPath()) ("lesson-promo-" + [System.Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $script:Scratch | Out-Null

    # A minimal but STRUCTURALLY REAL tree: a skill with a description and a lens anchor, an agent
    # body carrying the mandated load, and an exhibit under references/. Mutating one thing at a
    # time against this is what makes each red attributable to one cause.
    function script:New-ScratchTree {
        param([scriptblock]$Mutate)

        $dir = Join-Path $script:Scratch ([System.Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path (Join-Path $dir 'skills/demo-skill/references') | Out-Null
        New-Item -ItemType Directory -Force -Path (Join-Path $dir 'agents') | Out-Null

        $skillPath = Join-Path $dir 'skills/demo-skill/SKILL.md'
        Set-Content -LiteralPath $skillPath -Encoding utf8 -Value @'
---
name: demo-skill
description: "A demonstration skill. Use when reconciling a promoted roster against its receiving surfaces. DO NOT USE FOR: anything outside this fixture."
---

# Demo Skill

## Demo Lenses

> **Authoritative source**: Documents/Planning/lesson-promotion-manifest.json, enforced by .github/scripts/Tests/lesson-promotion-manifest.Tests.ps1. Renaming a heading below is a migration, not a regression.

#### A demo lens that carries its own actionable core

The core sentence a reader has to reach in this section. What follows exists so the fixture clears
the lens-body floor the way a real lens does, rather than passing because the floor was set low
enough to admit a pointer. A lens is the lesson's actionable core stated where the loading surface
puts it in front of a reader: what the trap looks like, the tell that you are inside it, and the
move that gets you out. A fixture whose lens is one sentence would make the floor untestable in the
direction that matters, because the positive control would then sit within a few characters of the
threshold and any later adjustment would silently flip it.

## Traps

[`references/demo-exhibit.md`](references/demo-exhibit.md) collects the traps.
'@

        $agentPath = Join-Path $dir 'agents/Demo.agent.md'
        Set-Content -LiteralPath $agentPath -Encoding utf8 -Value @'
# Demo Agent

## Skills Reference

- **Mandated load, unconditional** - load `skills/demo-skill/SKILL.md` before writing any claim
'@

        Set-Content -LiteralPath (Join-Path $dir 'skills/demo-skill/references/demo-exhibit.md') -Encoding utf8 -Value '# Demo exhibit'

        $manifest = [ordered]@{
            schema_version    = 1
            mandate_marker    = 'Mandated load, unconditional'
            roster_snapshot   = [ordered]@{ count = 2; snapshot_date = '2026-08-09' }
            declared_states   = @('promoted', 'recall-loss', 'pending')
            specificity_floor = [ordered]@{ min_length = 24; min_content_words = 3 }
            lens_body_floor   = [ordered]@{ min_chars = 300 }
            in_file_pins      = @(
                [ordered]@{ surface = 'skills/demo-skill/SKILL.md'; scope = 'section'; anchor = '## Demo Lenses'; must_contain = @('Authoritative source', 'migration, not a regression') }
            )
            loading_surfaces  = [ordered]@{
                'skills/demo-skill/SKILL.md' = [ordered]@{
                    loads_unconditionally_from = @(
                        [ordered]@{ surface = 'agents/Demo.agent.md'; anchor = '## Skills Reference'; text = 'load `skills/demo-skill/SKILL.md` before writing any claim' }
                    )
                }
            }
            entries           = @(
                [ordered]@{
                    lesson   = 'reference_demo_lesson'
                    state    = 'promoted'
                    chunk    = 1
                    issue    = 1049
                    kind     = 'lens'
                    fires_in = 'completion'
                    identity = 'name-keyed'
                    home     = 'skills/demo-skill/SKILL.md'
                    anchor   = '#### A demo lens that carries its own actionable core'
                    triggers = @(
                        [ordered]@{ surface = 'skills/demo-skill/SKILL.md'; surface_kind = 'description'; text = 'reconciling a promoted roster against its receiving surfaces' },
                        [ordered]@{ surface = 'skills/demo-skill/SKILL.md'; surface_kind = 'body'; anchor = '#### A demo lens that carries its own actionable core'; text = 'The core sentence a reader has to reach in this section' }
                    )
                    checked_against = [ordered]@{ verdict = 'clean'; surfaces = @('skills/demo-skill/SKILL.md'); note = 'fixture' }
                },
                [ordered]@{ lesson = 'reference_demo_pending'; state = 'pending'; chunk = 2; issue = 1050 }
            )
            exhibits          = @(
                [ordered]@{
                    file         = 'skills/demo-skill/references/demo-exhibit.md'
                    gating_skill = 'skills/demo-skill/SKILL.md'
                    cited_by     = @([ordered]@{ surface = 'skills/demo-skill/SKILL.md'; anchor = '## Traps' })
                    triggers     = @([ordered]@{ surface = 'skills/demo-skill/SKILL.md'; surface_kind = 'description'; text = 'reconciling a promoted roster against its receiving surfaces' })
                }
            )
        }

        $ctx = [PSCustomObject]@{
            Dir          = $dir
            SkillPath    = $skillPath
            AgentPath    = $agentPath
            ManifestPath = (Join-Path $dir 'lesson-promotion-manifest.json')
            Manifest     = $manifest
        }
        if ($Mutate) { & $Mutate $ctx }
        Set-Content -LiteralPath $ctx.ManifestPath -Encoding utf8 -Value ($ctx.Manifest | ConvertTo-Json -Depth 12)
        return $ctx
    }

    function script:Invoke-ScratchAudit {
        param([scriptblock]$Mutate)
        $t = script:New-ScratchTree -Mutate $Mutate
        return Get-LessonPromotionAudit -RepoRoot $t.Dir -ManifestPath $t.ManifestPath `
            -ExpectedRosterCount 2 -ExpectedPromotedByChunk @{ '1' = 1 } -ReceivingSkillDirs @('skills/demo-skill')
    }
}

AfterAll {
    if ($script:Scratch -and (Test-Path -LiteralPath $script:Scratch)) {
        Remove-Item -LiteralPath $script:Scratch -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Lesson promotion: the live tree' {

    It 'has no drift - every promoted lesson reaches a reader by the path the manifest claims' {
        $script:Live.DriftDetails -join ' | ' | Should -BeExactly ''
        $script:Live.HasDrift | Should -BeFalse
    }

    It 'actually audited something (a guard over an empty roster passes vacuously)' {
        $script:Live.Entries.Count | Should -Be $script:ExpectedRosterCount
        $script:Live.PromotedCount | Should -BeGreaterThan 0
    }

    It 'every promoted lens home is a loading surface, read from the surface rather than the kind field' {
        # AC4 independence, and it reads the SURFACE: `Test-Path` plus a check that the file's own
        # frontmatter declares it a skill or that it is an agent body. Deriving the type from the
        # path string alone would prove the path's shape, which is not what AC4 asked for.
        $m = Get-Content -LiteralPath $script:ManifestPath -Raw -Encoding utf8 | ConvertFrom-Json
        foreach ($e in @($m.entries | Where-Object { $_.state -eq 'promoted' })) {
            [string]$e.kind | Should -BeExactly 'lens' -Because "$($e.lesson) is a roster entry, whose only promoted kind is a lens"
            $abs = Join-Path $script:RepoRoot ([string]$e.home)
            (Test-Path -LiteralPath $abs -PathType Leaf) | Should -BeTrue -Because "$($e.lesson) names home $($e.home)"
            $first = @(Get-Content -LiteralPath $abs -TotalCount 5)
            if ([string]$e.home -like 'skills/*') {
                ($first -join "`n") | Should -Match '(?m)^name:\s' -Because "$($e.home) must be a skill body with frontmatter, not just a path that looks like one"
            }
            [string]$e.home | Should -Not -Match '/references/'
        }
    }

    It 'is itself selected by CI, so the guard cannot be dropped without dropping what would report it' {
        . (Join-Path $script:RepoRoot '.github/scripts/lib/ci-suite-selection-core.ps1')
        $sel = Get-CISuiteSelection -TestsRoot (Join-Path $script:RepoRoot '.github/scripts/Tests') -QuarantinePath (Join-Path $script:RepoRoot '.github/scripts/Tests/ci-quarantine.json')
        $sel.SelectedNames | Should -Contain 'lesson-promotion-manifest.Tests.ps1'
    }

    It 'a lesson already stated in shipped doctrine is promoted as a citing lens, not a restatement' {
        # An all-clean verdict set would mean the contradiction check never searched. This asserts
        # the population is non-empty in BOTH directions rather than pinning which lessons are in it.
        # The verdict VALUES are validated by the core, so they have fixture-level red states below.
        $m = Get-Content -LiteralPath $script:ManifestPath -Raw -Encoding utf8 | ConvertFrom-Json
        $promoted = @($m.entries | Where-Object { $_.state -eq 'promoted' })
        @($promoted | Where-Object { $_.checked_against.verdict -eq 'cite' }).Count | Should -BeGreaterThan 0
        @($promoted | Where-Object { $_.checked_against.verdict -eq 'clean' }).Count | Should -BeGreaterThan 0
    }
}

Describe 'Lesson promotion: one induced failure per class the guard claims to catch' {

    # --- Roster and state -----------------------------------------------------------------------

    It 'INDUCED (no-declared-state class): a roster entry in no declared state FAILS' {
        $r = script:Invoke-ScratchAudit { param($c) $c.Manifest.entries[0].state = 'half-done' }
        $r.HasDrift | Should -BeTrue
        ($r.DriftDetails -join ' ') | Should -Match 'is in no declared state'
    }

    It 'INDUCED (invented-state class): a fourth state declared AND used bypasses every promotion check, so it FAILS' {
        # The manifest-authority defect one level up, raised by the #1055 external review: only
        # `promoted` gets meaningful handling, so adding a string to BOTH an entry and
        # `declared_states` would let that entry skip every check while the declared-state
        # assertion stayed green. The set is validated against the fixed three, not merely used.
        $r = script:Invoke-ScratchAudit {
            param($c)
            $c.Manifest.declared_states = @('promoted', 'recall-loss', 'pending', 'half-done')
            $c.Manifest.entries[0].state = 'half-done'
        }
        $r.HasDrift | Should -BeTrue
        ($r.DriftDetails -join ' ') | Should -Match "declares state 'half-done', which is not one of"
    }

    It 'INDUCED (dropped-state class): omitting a required state from the declared set FAILS' {
        $r = script:Invoke-ScratchAudit { param($c) $c.Manifest.declared_states = @('promoted', 'pending') }
        $r.HasDrift | Should -BeTrue
        ($r.DriftDetails -join ' ') | Should -Match "does not declare the state 'recall-loss'"
    }

    It 'INDUCED (roster-truncation class): an entry removed AND the count decremented together FAILS' {
        # The half that matters. Leaving the anchor behind is caught by any intra-manifest
        # comparison; a consistent edit is caught only because the expected count lives here.
        $r = script:Invoke-ScratchAudit {
            param($c)
            $c.Manifest.entries = @($c.Manifest.entries[0])
            $c.Manifest.roster_snapshot.count = 1
        }
        $r.HasDrift | Should -BeTrue
        ($r.DriftDetails -join ' ') | Should -Match 'the caller expects a roster of 2 entries'
    }

    It 'INDUCED (promoted-share class): promoted entries relabelled `pending` FAILS' {
        # Without a caller-supplied share, relabelling every promoted row leaves the roster totalling
        # correctly and every surviving row checking out - the guard goes green over an empty promotion.
        $r = script:Invoke-ScratchAudit { param($c) $c.Manifest.entries[0].state = 'pending' }
        $r.HasDrift | Should -BeTrue
        ($r.DriftDetails -join ' ') | Should -Match 'chunk 1 is expected to have promoted 1 lessons, the manifest records 0'
    }

    It 'INDUCED (unbooked-recall-loss class): a promoted lesson relabelled `recall-loss` with no reason FAILS' {
        $r = script:Invoke-ScratchAudit {
            param($c)
            $c.Manifest.entries[0].state = 'recall-loss'
            $c.Manifest.entries[0].Remove('home')
        }
        $r.HasDrift | Should -BeTrue
        ($r.DriftDetails -join ' ') | Should -Match 'carries no recall_loss_reason'
    }

    It 'INDUCED (unowned-pending class): a pending row with no owning chunk or sub-issue FAILS' {
        $r = script:Invoke-ScratchAudit {
            param($c)
            $c.Manifest.entries[1].Remove('chunk')
            $c.Manifest.entries[1].Remove('issue')
        }
        $r.HasDrift | Should -BeTrue
        ($r.DriftDetails -join ' ') | Should -Match 'names no owning chunk'
        ($r.DriftDetails -join ' ') | Should -Match 'names no owning sub-issue'
    }

    It 'INDUCED (exhibit-only-promotion class): a promoted roster entry re-labelled kind=exhibit FAILS' {
        $r = script:Invoke-ScratchAudit { param($c) $c.Manifest.entries[0].kind = 'exhibit' }
        $r.HasDrift | Should -BeTrue
        ($r.DriftDetails -join ' ') | Should -Match "only promoted kind is 'lens'"
    }

    # --- Thresholds the manifest supplies ------------------------------------------------------

    It 'INDUCED (retuned-floor class): a zeroed lens-body floor FAILS instead of switching the check off' {
        # The cheapest way to silence a red is to disable the check that produced it. A floor of
        # zero is drift, not a relaxation.
        $r = script:Invoke-ScratchAudit { param($c) $c.Manifest.lens_body_floor.min_chars = 0 }
        $r.HasDrift | Should -BeTrue
        ($r.DriftDetails -join ' ') | Should -Match 'lens_body_floor.min_chars as 0; this reader owns that threshold'
    }

    It 'INDUCED (retuned-floor class, siblings): a zeroed specificity floor FAILS on either component' {
        $r1 = script:Invoke-ScratchAudit { param($c) $c.Manifest.specificity_floor.min_length = 0 }
        ($r1.DriftDetails -join ' ') | Should -Match 'specificity_floor.min_length as 0; this reader owns that threshold'
        $r2 = script:Invoke-ScratchAudit { param($c) $c.Manifest.specificity_floor.min_content_words = 0 }
        ($r2.DriftDetails -join ' ') | Should -Match 'specificity_floor.min_content_words as 0; this reader owns that threshold'
    }

    It 'INDUCED (emptied-collection class): an emptied loader list or pin list FAILS' {
        $r1 = script:Invoke-ScratchAudit { param($c) $c.Manifest.loading_surfaces['skills/demo-skill/SKILL.md'].loads_unconditionally_from = @() }
        $r1.HasDrift | Should -BeTrue
        ($r1.DriftDetails -join ' ') | Should -Match 'loads_unconditionally_from list is empty'
        $r2 = script:Invoke-ScratchAudit { param($c) $c.Manifest.in_file_pins = @() }
        $r2.HasDrift | Should -BeTrue
        ($r2.DriftDetails -join ' ') | Should -Match 'declares no in_file_pins'
    }

    # --- Trigger integrity ---------------------------------------------------------------------

    It 'INDUCED (description-deletion class): a trigger deleted from a DESCRIPTION FAILS' {
        $r = script:Invoke-ScratchAudit {
            param($c)
            $body = Get-Content -LiteralPath $c.SkillPath -Raw -Encoding utf8
            Set-Content -LiteralPath $c.SkillPath -Encoding utf8 -Value ($body -replace 'reconciling a promoted roster against its receiving surfaces', 'doing things')
        }
        $r.HasDrift | Should -BeTrue
        ($r.DriftDetails -join ' ') | Should -Match "condition text absent from that skill's description"
    }

    It 'INDUCED (body-deletion class): a trigger deleted from a BODY surface FAILS' {
        $r = script:Invoke-ScratchAudit {
            param($c)
            $body = Get-Content -LiteralPath $c.SkillPath -Raw -Encoding utf8
            Set-Content -LiteralPath $c.SkillPath -Encoding utf8 -Value ($body -replace 'The core sentence a reader has to reach in this section\.', 'Something else entirely happens here.')
        }
        $r.HasDrift | Should -BeTrue
        ($r.DriftDetails -join ' ') | Should -Match 'names text absent from the section anchored at'
    }

    It 'INDUCED (body-anchor-rename class): a renamed heading on a BODY surface FAILS' {
        $r = script:Invoke-ScratchAudit {
            param($c)
            $body = Get-Content -LiteralPath $c.SkillPath -Raw -Encoding utf8
            Set-Content -LiteralPath $c.SkillPath -Encoding utf8 -Value ($body -replace '#### A demo lens that carries its own actionable core', '#### A demo lens, renamed')
        }
        $r.HasDrift | Should -BeTrue
        ($r.DriftDetails -join ' ') | Should -Match 'which that file does not carry|which that surface does not carry'
    }

    It 'INDUCED (agent-body-anchor-rename class): a renamed heading on an AGENT BODY FAILS' {
        $r = script:Invoke-ScratchAudit {
            param($c)
            $body = Get-Content -LiteralPath $c.AgentPath -Raw -Encoding utf8
            Set-Content -LiteralPath $c.AgentPath -Encoding utf8 -Value ($body -replace '## Skills Reference', '## Skills')
        }
        $r.HasDrift | Should -BeTrue
        ($r.DriftDetails -join ' ') | Should -Match "mandated load of 'skills/demo-skill/SKILL.md'.*does not carry"
    }

    It 'INDUCED (agent-body-deletion class): the mandated load text deleted from an AGENT BODY FAILS' {
        $r = script:Invoke-ScratchAudit {
            param($c)
            $body = Get-Content -LiteralPath $c.AgentPath -Raw -Encoding utf8
            Set-Content -LiteralPath $c.AgentPath -Encoding utf8 -Value ($body -replace 'load `skills/demo-skill/SKILL\.md` before writing any claim', 'consult the skills index when it seems relevant')
        }
        $r.HasDrift | Should -BeTrue
        ($r.DriftDetails -join ' ') | Should -Match 'mandated load .* names text absent from the section'
    }

    It 'INDUCED (negated-mandate class): a mandate rewritten as a PERMISSION, keeping the pinned substring, FAILS' {
        # The substring survives every rewording. "load X before writing any claim" and "you may
        # load X before writing any claim" are the same to a `Contains` and opposite to a reader -
        # which is the defect `pin_by_substring_is_not_a_pin` names, inside the layer called
        # "unconditional".
        $r = script:Invoke-ScratchAudit {
            param($c)
            $body = Get-Content -LiteralPath $c.AgentPath -Raw -Encoding utf8
            Set-Content -LiteralPath $c.AgentPath -Encoding utf8 -Value ($body -replace '- \*\*Mandated load, unconditional\*\* - load', '- **Optional** - you may load')
        }
        $r.HasDrift | Should -BeTrue
        ($r.DriftDetails -join ' ') | Should -Match 'is not unconditional'
    }

    It 'CONTROL (mandate strengthening): "not only when X" is a mandate, not a permission' {
        # Without this the negator scan reads a negation of a negation as the thing it negates, and
        # the live tree - whose three loads all say "not only when ..." - would be red for prose
        # that is stronger than the bare imperative.
        (Test-LPMandateIsUnconditional -SectionLines @('- **Mandated load, unconditional** - load `skills/x/SKILL.md` before any claim, not only when validating') `
                -SkillPath 'skills/x/SKILL.md' -MandateMarker 'Mandated load, unconditional').Count | Should -Be 0
    }

    It 'INDUCED (neutering-by-relocation class): a trigger moved into the DO NOT USE FOR clause FAILS' {
        $r = script:Invoke-ScratchAudit {
            param($c)
            $body = Get-Content -LiteralPath $c.SkillPath -Raw -Encoding utf8
            $body = $body -replace 'Use when reconciling a promoted roster against its receiving surfaces\. ', ''
            $body = $body -replace 'DO NOT USE FOR: anything outside this fixture\.', 'DO NOT USE FOR: reconciling a promoted roster against its receiving surfaces.'
            Set-Content -LiteralPath $c.SkillPath -Encoding utf8 -Value $body
        }
        $r.HasDrift | Should -BeTrue
        ($r.DriftDetails -join ' ') | Should -Match 'present only inside the DO NOT USE FOR clause'
    }

    It 'INDUCED (specificity-floor LENGTH component): a trigger too short to locate anything FAILS' {
        $r = script:Invoke-ScratchAudit {
            param($c)
            $body = Get-Content -LiteralPath $c.SkillPath -Raw -Encoding utf8
            Set-Content -LiteralPath $c.SkillPath -Encoding utf8 -Value ($body -replace 'reconciling a promoted roster against its receiving surfaces', 'roster work')
            $c.Manifest.entries[0].triggers[0].text = 'roster work'
            $c.Manifest.exhibits[0].triggers[0].text = 'roster work'
        }
        $r.HasDrift | Should -BeTrue
        ($r.DriftDetails -join ' ') | Should -Match 'below the specificity floor on length'
    }

    It 'INDUCED (specificity-floor CONTENT-WORD component): a long trigger of only filler words FAILS' {
        $filler = 'when they have been about that which they were'
        $r = script:Invoke-ScratchAudit {
            param($c)
            $body = Get-Content -LiteralPath $c.SkillPath -Raw -Encoding utf8
            Set-Content -LiteralPath $c.SkillPath -Encoding utf8 -Value ($body -replace 'reconciling a promoted roster against its receiving surfaces', $filler)
            $c.Manifest.entries[0].triggers[0].text = $filler
            $c.Manifest.exhibits[0].triggers[0].text = $filler
        }
        $r.HasDrift | Should -BeTrue
        ($r.DriftDetails -join ' ') | Should -Match 'below the specificity floor on content words'
        ($r.DriftDetails -join ' ') | Should -Not -Match 'below the specificity floor on length'
    }

    It 'INDUCED (whole-file-scope class): a body trigger with no named anchor FAILS' {
        $r = script:Invoke-ScratchAudit { param($c) $c.Manifest.entries[0].triggers[1].anchor = '' }
        $r.HasDrift | Should -BeTrue
        ($r.DriftDetails -join ' ') | Should -Match 'scoped to the whole file rather than to a named anchor'
    }

    It 'INDUCED (broken-chain class, surface): a trigger recorded on a skill other than the lesson home FAILS' {
        # Each clause can check out while the three of them describe no single walk: a reader who
        # follows the recorded trigger loads a skill that does not carry the lens.
        $r = script:Invoke-ScratchAudit {
            param($c)
            New-Item -ItemType Directory -Force -Path (Join-Path $c.Dir 'skills/other-skill') | Out-Null
            Set-Content -LiteralPath (Join-Path $c.Dir 'skills/other-skill/SKILL.md') -Encoding utf8 -Value @'
---
name: other-skill
description: "Another skill. Use when reconciling a promoted roster against its receiving surfaces. DO NOT USE FOR: nothing."
---

# Other
'@
            $c.Manifest.entries[0].triggers[0].surface = 'skills/other-skill/SKILL.md'
        }
        $r.HasDrift | Should -BeTrue
        ($r.DriftDetails -join ' ') | Should -Match "names a surface other than the lesson's home"
    }

    It 'INDUCED (broken-chain class, anchor): a body trigger pointing at a section the promotion never wrote FAILS' {
        $r = script:Invoke-ScratchAudit {
            param($c)
            $c.Manifest.entries[0].triggers[1].anchor = '## Traps'
        }
        $r.HasDrift | Should -BeTrue
        ($r.DriftDetails -join ' ') | Should -Match "which is not the lesson's own anchor"
    }

    # --- Lens substance and fences --------------------------------------------------------------

    It 'INDUCED (pointer-lens class): a lens gutted to a pointer, keeping its pinned trigger, FAILS' {
        $r = script:Invoke-ScratchAudit {
            param($c)
            $body = Get-Content -LiteralPath $c.SkillPath -Raw -Encoding utf8
            $body = $body -replace '(?s)(#### A demo lens that carries its own actionable core\r?\n\r?\n).*?(\r?\n\r?\n## Traps)',
                                   '$1See the promotion manifest. The core sentence a reader has to reach in this section.$2'
            Set-Content -LiteralPath $c.SkillPath -Encoding utf8 -Value $body
        }
        $r.HasDrift | Should -BeTrue
        ($r.DriftDetails -join ' ') | Should -Match 'below the lens-body floor'
    }

    It 'INDUCED (fenced-impersonation class): a lens deleted with only a fenced copy left behind FAILS' {
        # The worst false green an unfenced heading scan produces: the reader-facing lens is gone,
        # the surviving text is a code sample nobody reads as guidance, and every trigger assertion
        # still matches.
        $r = script:Invoke-ScratchAudit {
            param($c)
            $body = Get-Content -LiteralPath $c.SkillPath -Raw -Encoding utf8
            $lens = [regex]::Match($body, '(?s)#### A demo lens that carries its own actionable core.*?(?=\r?\n## Traps)').Value
            $fenced = "## Illustrative example`n`n" + '```markdown' + "`n" + $lens + "`n" + '```' + "`n"
            Set-Content -LiteralPath $c.SkillPath -Encoding utf8 -Value ($body -replace [regex]::Escape($lens), $fenced)
        }
        $r.HasDrift | Should -BeTrue
        ($r.DriftDetails -join ' ') | Should -Match 'which that file does not carry'
    }

    It 'INDUCED (fenced-trigger class): a trigger surviving only inside a fenced block FAILS' {
        $r = script:Invoke-ScratchAudit {
            param($c)
            $body = Get-Content -LiteralPath $c.SkillPath -Raw -Encoding utf8
            $body = $body -replace 'The core sentence a reader has to reach in this section\.',
                                   ("Formerly:`n`n" + '```text' + "`nThe core sentence a reader has to reach in this section.`n" + '```')
            Set-Content -LiteralPath $c.SkillPath -Encoding utf8 -Value $body
        }
        $r.HasDrift | Should -BeTrue
        ($r.DriftDetails -join ' ') | Should -Match 'survives only inside a fenced block'
    }

    It 'CONTROL (fence-aware sectioning): a fenced heading inside a lens does not truncate its section' {
        $t = script:New-ScratchTree -Mutate {
            param($c)
            $body = Get-Content -LiteralPath $c.SkillPath -Raw -Encoding utf8
            # The fence must open at the start of a line, or it is not a fence and the test would
            # be asserting something the markdown does not say.
            Set-Content -LiteralPath $c.SkillPath -Encoding utf8 -Value ($body -replace 'A fixture whose lens is one sentence',
                ("`n" + '```powershell' + "`n# a comment that is not a heading`n" + '```' + "`n`nA fixture whose lens is one sentence"))
        }
        $sec = Get-LPSection -Path $t.SkillPath -Anchor '#### A demo lens that carries its own actionable core'
        $sec.Text | Should -Match 'threshold and any later adjustment'
        $sec.UnfencedText | Should -Not -Match 'a comment that is not a heading'
    }

    # --- Exhibits ------------------------------------------------------------------------------

    It 'INDUCED (orphan-exhibit class): an exhibit no surface cites FAILS' {
        $r = script:Invoke-ScratchAudit {
            param($c)
            $body = Get-Content -LiteralPath $c.SkillPath -Raw -Encoding utf8
            Set-Content -LiteralPath $c.SkillPath -Encoding utf8 -Value ($body -replace '\[`references/demo-exhibit\.md`\]\(references/demo-exhibit\.md\) collects the traps\.', 'Traps are collected elsewhere.')
        }
        $r.HasDrift | Should -BeTrue
        ($r.DriftDetails -join ' ') | Should -Match "points at a section that never mentions 'demo-exhibit.md'"
    }

    It 'INDUCED (de-manifested-exhibit class): deleting an exhibit row does NOT also de-scope its directory' {
        # The reverse scan's population comes from the caller, so removing the row leaves the file
        # unaccounted rather than removing the directory the accounting would have happened in.
        $r = script:Invoke-ScratchAudit { param($c) $c.Manifest.exhibits = @() }
        $r.HasDrift | Should -BeTrue
        ($r.DriftDetails -join ' ') | Should -Match "'skills/demo-skill/references/demo-exhibit.md' sits in a receiving references directory with no manifest row"
    }

    It 'INDUCED (unmanifested-references-file class): a references file with no manifest row FAILS, at any depth' {
        $r1 = script:Invoke-ScratchAudit {
            param($c)
            Set-Content -LiteralPath (Join-Path $c.Dir 'skills/demo-skill/references/stowaway.md') -Encoding utf8 -Value '# Stowaway'
        }
        ($r1.DriftDetails -join ' ') | Should -Match "'skills/demo-skill/references/stowaway.md' sits in a receiving references directory"

        $r2 = script:Invoke-ScratchAudit {
            param($c)
            New-Item -ItemType Directory -Force -Path (Join-Path $c.Dir 'skills/demo-skill/references/sub') | Out-Null
            Set-Content -LiteralPath (Join-Path $c.Dir 'skills/demo-skill/references/sub/deep.md') -Encoding utf8 -Value '# Deep'
        }
        ($r2.DriftDetails -join ' ') | Should -Match 'references/sub/deep.md'
    }

    It 'INDUCED (forward-citation class): a lens citing an exhibit no manifest row carries FAILS' {
        $r = script:Invoke-ScratchAudit {
            param($c)
            $body = Get-Content -LiteralPath $c.SkillPath -Raw -Encoding utf8
            Set-Content -LiteralPath $c.SkillPath -Encoding utf8 -Value ($body -replace 'The core sentence a reader has to reach in this section\.', 'The core sentence a reader has to reach in this section. See references/not-yet-shipped.md.')
        }
        $r.HasDrift | Should -BeTrue
        ($r.DriftDetails -join ' ') | Should -Match "cites 'references/not-yet-shipped.md'"
    }

    It 'INDUCED (cross-skill-citation class): a citation resolving to a path this skill does not have FAILS' {
        # A suffix match certifies a link that is dead for the reader of the citing skill whenever
        # any OTHER skill happens to carry a same-named exhibit.
        $r = script:Invoke-ScratchAudit {
            param($c)
            New-Item -ItemType Directory -Force -Path (Join-Path $c.Dir 'skills/other-skill/references') | Out-Null
            Set-Content -LiteralPath (Join-Path $c.Dir 'skills/other-skill/references/elsewhere.md') -Encoding utf8 -Value '# Elsewhere'
            $c.Manifest.exhibits += [ordered]@{
                file         = 'skills/other-skill/references/elsewhere.md'
                gating_skill = 'skills/other-skill/SKILL.md'
                cited_by     = @()
                triggers     = @()
            }
            $body = Get-Content -LiteralPath $c.SkillPath -Raw -Encoding utf8
            Set-Content -LiteralPath $c.SkillPath -Encoding utf8 -Value ($body -replace 'The core sentence a reader has to reach in this section\.', 'The core sentence a reader has to reach in this section. See references/elsewhere.md.')
        }
        $r.HasDrift | Should -BeTrue
        ($r.DriftDetails -join ' ') | Should -Match "cites 'references/elsewhere.md' \(resolving to 'skills/demo-skill/references/elsewhere.md'\)"
    }

    It 'CONTROL (citation boundary): a path segment merely ENDING in "references" is not read as an exhibit citation' {
        $r = script:Invoke-ScratchAudit {
            param($c)
            $body = Get-Content -LiteralPath $c.SkillPath -Raw -Encoding utf8
            Set-Content -LiteralPath $c.SkillPath -Encoding utf8 -Value ($body -replace 'The core sentence a reader has to reach in this section\.', 'The core sentence a reader has to reach in this section. See skills/project-references/SKILL.md for sidecars.')
        }
        ($r.DriftDetails -join ' ') | Should -Not -Match 'project-references'
    }

    # --- Verdicts ------------------------------------------------------------------------------

    It 'INDUCED (missing-verdict class): a promoted entry with a blanked or invented verdict FAILS' {
        $r1 = script:Invoke-ScratchAudit { param($c) $c.Manifest.entries[0].checked_against.verdict = '' }
        ($r1.DriftDetails -join ' ') | Should -Match "records verdict '', which is not one of"
        $r2 = script:Invoke-ScratchAudit { param($c) $c.Manifest.entries[0].Remove('checked_against') }
        ($r2.DriftDetails -join ' ') | Should -Match 'records no checked_against verdict'
    }

    It 'INDUCED (unresolved-conflict class): a conflict verdict carrying NO resolution FAILS' {
        # Re-pointed, not deleted (parent #1045 amendment A4.5). Before that amendment EVERY
        # conflict was drift, which made the state the contradiction procedure describes -
        # a shipped sentence the promoted lesson itself falsified, corrected in the same change -
        # unwritable in any value the vocabulary admits. The cheap resolution was to widen the enum
        # and delete this fixture; the guard survives instead, narrowed to the unresolved case.
        $r = script:Invoke-ScratchAudit { param($c) $c.Manifest.entries[0].checked_against.verdict = 'conflict' }
        $r.HasDrift | Should -BeTrue
        ($r.DriftDetails -join ' ') | Should -Match 'with no resolution'
    }

    It 'INDUCED (stub-resolution class): a conflict whose resolution is too short to name what moved FAILS' {
        $r = script:Invoke-ScratchAudit { param($c)
            $c.Manifest.entries[0].checked_against.verdict = 'conflict'
            $c.Manifest.entries[0].checked_against['resolution'] = 'fixed it'
        }
        $r.HasDrift | Should -BeTrue
        ($r.DriftDetails -join ' ') | Should -Match 'is a label, not a resolution'
    }

    It 'A conflict verdict carrying its resolution is LAWFUL - the amendment is a narrowing, not a removal' {
        # The other polarity. Without this the two tests above are satisfied by a check that reds on
        # every conflict, which is the pre-amendment behaviour wearing new message text.
        $r = script:Invoke-ScratchAudit { param($c)
            $c.Manifest.entries[0].checked_against.verdict = 'conflict'
            $c.Manifest.entries[0].checked_against['resolution'] = 'The stale allowlist sentence at skills/terminal-hygiene/SKILL.md:36 was corrected in this change.'
        }
        ($r.DriftDetails -join ' ') | Should -Not -Match 'conflict'
    }

    It 'INDUCED (resolution-without-conflict class): a resolution beside a clean verdict FAILS' {
        $r = script:Invoke-ScratchAudit { param($c)
            $c.Manifest.entries[0].checked_against['resolution'] = 'A resolution long enough to clear the floor but attached to no contradiction at all.'
        }
        $r.HasDrift | Should -BeTrue
        ($r.DriftDetails -join ' ') | Should -Match 'means nothing beside any other verdict'
    }

    # --- fires_in vocabulary (parent #1045 amendment A4.6) ---------------------------------------

    It 'INDUCED (undeclared-phase class): a fires_in value outside the declaration FAILS' {
        # The real defect A4.6 records is not which words won: it is that a field the design calls a
        # declared enum had NO assertion behind it, so the shipped vocabulary and the declared one
        # diverged for a whole chunk and its review without anything noticing. This is that
        # assertion. A green run over conforming rows is not evidence it exists; only this red is.
        $r = script:Invoke-ScratchAudit { param($c) $c.Manifest.entries[0].fires_in = 'planning' }
        $r.HasDrift | Should -BeTrue
        ($r.DriftDetails -join ' ') | Should -Match "declares fires_in 'planning', which is not one of"
    }

    It 'INDUCED (undeclared-phase class): a promoted entry with fires_in removed FAILS' {
        $r = script:Invoke-ScratchAudit { param($c) $c.Manifest.entries[0].Remove('fires_in') }
        $r.HasDrift | Should -BeTrue
        ($r.DriftDetails -join ' ') | Should -Match "declares fires_in ''"
    }

    # --- Derived consumer type (parent #1045 amendment A4.3) -------------------------------------
    #
    # The limb is DERIVED FROM THE TREE, never declared in the manifest. These three run as one
    # argument and are worth reading together, because either half alone is misleading: the first
    # shows the relaxation is real, the second and third show it is not a hole.

    It 'A lens home no agent body mandates is LAWFUL with no loader entry - the main-session-only reading' {
        $t = script:New-ScratchTree { param($c)
            $c.Manifest.loading_surfaces = [ordered]@{}
            # Strip the mandate from the body, so the tree says nothing loads this skill into a
            # subagent. Under the pre-amendment check this state was red and the only escapes were
            # re-homing away from the phase the skill names, or adding a mandated load to a body
            # that does not do the work.
            Set-Content -LiteralPath $c.AgentPath -Encoding utf8 -Value "# Demo Agent`n`n## Skills Reference`n`n- Nothing is mandated here.`n"
        }
        $r = Get-LessonPromotionAudit -RepoRoot $t.Dir -ManifestPath $t.ManifestPath `
            -ExpectedRosterCount 2 -ExpectedPromotedByChunk @{ '1' = 1 } -ReceivingSkillDirs @('skills/demo-skill')
        ($r.DriftDetails -join ' ') | Should -Not -Match 'unconditional loader'
        ($r.DriftDetails -join ' ') | Should -Not -Match 'not main-session-only'
    }

    It 'INDUCED (undeclared-chunk class): a promoted share under a chunk key the caller never declared FAILS' {
        # The quietest escape this chunk could have created. The per-chunk loop iterates the
        # CALLER's keys, so a chunk promoting lessons under a key nobody declared is counted by
        # nothing at all - the roster still totals and every surviving row still checks out. An
        # absent key is not a mismatched one, so this needs its own clause and its own mutation:
        # setting the key to a wrong NUMBER exercises a different branch entirely.
        $t = script:New-ScratchTree { }
        $r = Get-LessonPromotionAudit -RepoRoot $t.Dir -ManifestPath $t.ManifestPath `
            -ExpectedRosterCount 2 -ExpectedPromotedByChunk @{ '9' = 0 } -ReceivingSkillDirs @('skills/demo-skill')
        $r.HasDrift | Should -BeTrue
        ($r.DriftDetails -join ' ') | Should -Match 'which the caller.s expected-share map does not declare'
    }

    It 'INDUCED (retuned-marker class): a mandate_marker that appears in no agent body FAILS' {
        # The one HIGH finding of PR #1061's review, and the sharpest shape in this file: the A4.3
        # derivation reads the tree, but its only INPUT is a manifest field. Point mandate_marker at
        # a string that appears nowhere and the derived set empties, every lens home reads
        # main-session-only, and an emptied loading_surfaces then audits clean. Reproduced on the
        # real manifest before the fix: two tokens took 43 drift findings to zero. Non-blankness was
        # never the property that mattered. Nor was reaching the tree: defense showed any real
        # agent-body string is findable and still derives nothing, so the marker is core-owned and
        # a manifest that disagrees is drift whatever its value. The sibling test below uses a
        # string that DOES exist in the tree, which is what discriminates this fix from that one.
        $r = script:Invoke-ScratchAudit { param($c)
            $c.Manifest.mandate_marker = 'Mandated load, unconditionally'
            $c.Manifest.loading_surfaces = [ordered]@{}
        }
        $r.HasDrift | Should -BeTrue
        ($r.DriftDetails -join ' ') | Should -Match 'this reader owns that vocabulary'
    }

    It 'INDUCED (retuned-marker class): a manifest marker that is REAL but derives nothing FAILS' {
        # The first fix for this escape required the marker to be FINDABLE in an agent body, and
        # defense falsified it in one pass: any real string occurring anywhere in any agent body
        # is findable and derives ZERO mandated loads, so the two-token escape reopened unchanged.
        # The marker is now core-owned; a manifest that disagrees is drift regardless of whether
        # its value exists in the tree. This fixture uses a string that DOES exist in a real agent
        # body, which is what makes it discriminating against the previous fix.
        $r = script:Invoke-ScratchAudit { param($c)
            $c.Manifest.mandate_marker = 'Core Principles'
            $c.Manifest.loading_surfaces = [ordered]@{}
        }
        $r.HasDrift | Should -BeTrue
        ($r.DriftDetails -join ' ') | Should -Match 'this reader owns that vocabulary'
    }

    It 'INDUCED (absent-population class): no agents directory FAILS rather than deriving an empty set' {
        $t = script:New-ScratchTree { $c = $args[0]; $c.Manifest.loading_surfaces = [ordered]@{} }
        Remove-Item -LiteralPath (Join-Path $t.Dir 'agents') -Recurse -Force
        $r = Get-LessonPromotionAudit -RepoRoot $t.Dir -ManifestPath $t.ManifestPath `
            -ExpectedRosterCount 2 -ExpectedPromotedByChunk @{ '1' = 1 } -ReceivingSkillDirs @('skills/demo-skill')
        $r.HasDrift | Should -BeTrue
        ($r.DriftDetails -join ' ') | Should -Match 'has no population and would read every lens home as main-session-only'
    }

    It 'A mandate quoted inside a FENCED block is not read as a live subagent consumer' {
        # Every other reader in this file is fence-aware. When this one was not, a fenced example
        # made the home a subagent consumer to the derivation while layer 4 (which matches unfenced
        # text) refused the loader entry - so the home had NO writable green state, which is the
        # unsatisfiable shape amendment A4.5 exists to remove, reproduced one function over.
        $t = script:New-ScratchTree { param($c)
            $c.Manifest.loading_surfaces = [ordered]@{}
            Set-Content -LiteralPath $c.AgentPath -Encoding utf8 -Value "# Demo Agent`n`n## Skills Reference`n`n- **Mandated load, unconditional** - load ``skills/other-skill/SKILL.md`` here.`n`nHistorical example, no longer in force:`n`n``````markdown`n- **Mandated load, unconditional** - load ``skills/demo-skill/SKILL.md`` before writing any claim`n```````n"
        }
        $r = Get-LessonPromotionAudit -RepoRoot $t.Dir -ManifestPath $t.ManifestPath `
            -ExpectedRosterCount 2 -ExpectedPromotedByChunk @{ '1' = 1 } -ReceivingSkillDirs @('skills/demo-skill')
        ($r.DriftDetails -join ' ') | Should -Not -Match 'not main-session-only'
    }

    It 'A mandate whose marker and skill path wrap onto separate lines IS derived' {
        # A single-line search reads a markdown list-continuation as no mandate at all, which makes
        # A4.3's stated safety property ("adding a mandated load turns this red") false for any
        # mandate long enough to wrap - and several live mandate lines exceed 200 characters.
        $t = script:New-ScratchTree { param($c)
            $c.Manifest.loading_surfaces = [ordered]@{}
            Set-Content -LiteralPath $c.AgentPath -Encoding utf8 -Value "# Demo Agent`n`n## Skills Reference`n`n- **Mandated load, unconditional** -`n  load ``skills/demo-skill/SKILL.md`` before writing any claim`n"
        }
        $r = Get-LessonPromotionAudit -RepoRoot $t.Dir -ManifestPath $t.ManifestPath `
            -ExpectedRosterCount 2 -ExpectedPromotedByChunk @{ '1' = 1 } -ReceivingSkillDirs @('skills/demo-skill')
        $r.HasDrift | Should -BeTrue
        ($r.DriftDetails -join ' ') | Should -Match 'not main-session-only'
    }

    It 'An object with ZERO properties produces findings, not a StrictMode crash' {
        # Regression guard. `$o.PSObject.Properties.Name` throws under StrictMode 3.0 when the
        # property collection is empty, and an empty `loading_surfaces` became a lawful shape the
        # moment A4.3 allowed every home to be main-session-only - so the missing-property guard was
        # itself throwing on the emptiest object it could be handed. Found by running the amendment's
        # own new tests, not by reading the diff.
        $probe = '{}' | ConvertFrom-Json
        { Get-LPField $probe 'anything' } | Should -Not -Throw
        Get-LPField $probe 'anything' 'fallback' | Should -BeExactly 'fallback'
    }

    It 'INDUCED (asserted-consumer-type class): a mandated load in the tree with NO loader entry FAILS' {
        # The same manifest as the test above - only the tree differs. That is the whole point of
        # deriving: the manifest cannot buy itself the main-session-only reading, because the
        # predicate is not one of its fields.
        $t = script:New-ScratchTree { param($c) $c.Manifest.loading_surfaces = [ordered]@{} }
        $r = Get-LessonPromotionAudit -RepoRoot $t.Dir -ManifestPath $t.ManifestPath `
            -ExpectedRosterCount 2 -ExpectedPromotedByChunk @{ '1' = 1 } -ReceivingSkillDirs @('skills/demo-skill')
        $r.HasDrift | Should -BeTrue
        ($r.DriftDetails -join ' ') | Should -Match 'a home with a subagent consumer is not main-session-only'
        ($r.DriftDetails -join ' ') | Should -Match 'agents/Demo\.agent\.md'
    }

    It 'A load line carrying a permission phrase does NOT make a home a subagent consumer' {
        # The derived set reads the mandate-marker-bearing loads and applies the same negator test
        # the layer-4 assertions do, so the two cannot disagree about what counts as unconditional.
        $t = script:New-ScratchTree { param($c)
            $c.Manifest.loading_surfaces = [ordered]@{}
            Set-Content -LiteralPath $c.AgentPath -Encoding utf8 -Value "# Demo Agent`n`n## Skills Reference`n`n- **Mandated load, unconditional** - you may load ``skills/demo-skill/SKILL.md`` if relevant`n"
        }
        $r = Get-LessonPromotionAudit -RepoRoot $t.Dir -ManifestPath $t.ManifestPath `
            -ExpectedRosterCount 2 -ExpectedPromotedByChunk @{ '1' = 1 } -ReceivingSkillDirs @('skills/demo-skill')
        ($r.DriftDetails -join ' ') | Should -Not -Match 'not main-session-only'
    }

    It 'An illustrative skill path with no mandate marker does NOT make a home a subagent consumer' {
        $t = script:New-ScratchTree { param($c)
            $c.Manifest.loading_surfaces = [ordered]@{}
            Set-Content -LiteralPath $c.AgentPath -Encoding utf8 -Value "# Demo Agent`n`n## Skills Reference`n`n- For example, an adapter may live at ``skills/demo-skill/SKILL.md``.`n"
        }
        $r = Get-LessonPromotionAudit -RepoRoot $t.Dir -ManifestPath $t.ManifestPath `
            -ExpectedRosterCount 2 -ExpectedPromotedByChunk @{ '1' = 1 } -ReceivingSkillDirs @('skills/demo-skill')
        ($r.DriftDetails -join ' ') | Should -Not -Match 'not main-session-only'
    }

    # --- Composite-convention deferral arm (parent #1045 amendments A3 and A4.4) ------------------

    It 'INDUCED (unlisted-composite class): a references file missing from a skill that CARRIES the convention FAILS' {
        $t = script:New-ScratchTree { param($c)
            $body = Get-Content -LiteralPath $c.SkillPath -Raw -Encoding utf8
            # Adopt the convention, but list nothing.
            $body = $body -replace '## Traps', "## Composite References`n`n- nothing is listed here`n`n## Traps"
            Set-Content -LiteralPath $c.SkillPath -Encoding utf8 -Value $body
        }
        $r = Get-LessonPromotionAudit -RepoRoot $t.Dir -ManifestPath $t.ManifestPath `
            -ExpectedRosterCount 2 -ExpectedPromotedByChunk @{ '1' = 1 } -ReceivingSkillDirs @('skills/demo-skill')
        $r.HasDrift | Should -BeTrue
        ($r.DriftDetails -join ' ') | Should -Match "is not named in 'skills/demo-skill/SKILL.md' section 'Composite References'"
    }

    It 'A skill carrying the convention and listing every file is LAWFUL' {
        $t = script:New-ScratchTree { param($c)
            $body = Get-Content -LiteralPath $c.SkillPath -Raw -Encoding utf8
            $body = $body -replace '## Traps', "## Composite References`n`n- [references/demo-exhibit.md](references/demo-exhibit.md): the demo traps`n`n## Traps"
            Set-Content -LiteralPath $c.SkillPath -Encoding utf8 -Value $body
        }
        $r = Get-LessonPromotionAudit -RepoRoot $t.Dir -ManifestPath $t.ManifestPath `
            -ExpectedRosterCount 2 -ExpectedPromotedByChunk @{ '1' = 1 } -ReceivingSkillDirs @('skills/demo-skill')
        ($r.DriftDetails -join ' ') | Should -Not -Match 'Composite References'
    }

    It 'A skill NOT carrying the convention is judged by the manifest registry alone' {
        # A3's other arm, and the reason the check does not simply demand the convention everywhere:
        # reading a convention no receiving skill carries would be a check with no population. The
        # base fixture has no Composite References section at all.
        $r = script:Invoke-ScratchAudit { }
        ($r.DriftDetails -join ' ') | Should -Not -Match 'Composite References'
    }

    It 'INDUCED (unreproducible-provenance class): a machine-local path recorded as a searched surface FAILS' {
        $r = script:Invoke-ScratchAudit { param($c) $c.Manifest.entries[0].checked_against.surfaces = @('C:\Users\Someone', 'CLAUDE.md') }
        $r.HasDrift | Should -BeTrue
        ($r.DriftDetails -join ' ') | Should -Match 'machine-local path rather than a repository-relative surface'
    }

    # --- Manifest shape: findings, never crashes ------------------------------------------------

    It 'INDUCED (missing-field class): a row missing a field produces a NAMED finding, not a crash' {
        # Under StrictMode an unguarded property read throws, and because the live audit runs in
        # BeforeAll one hand-edited row would take every other assertion down with it - a crash
        # where a finding belongs, naming a JSON property rather than a lesson.
        foreach ($field in @('kind', 'anchor', 'triggers', 'home', 'state')) {
            $r = script:Invoke-ScratchAudit ([scriptblock]::Create("param(`$c) `$c.Manifest.entries[0].Remove('$field')"))
            $r.HasDrift | Should -BeTrue -Because "removing '$field' must be reported"
            ($r.DriftDetails -join ' ') | Should -Match 'reference_demo_lesson' -Because "the finding for a missing '$field' must name the lesson"
        }
    }

    It 'INDUCED (wrong-shape class): well-formed JSON of the wrong shape FAILS instead of crashing' {
        $t = script:New-ScratchTree
        Set-Content -LiteralPath $t.ManifestPath -Encoding utf8 -Value '{ "entries": [] }'
        $r = Get-LessonPromotionAudit -RepoRoot $t.Dir -ManifestPath $t.ManifestPath -ReceivingSkillDirs @('skills/demo-skill')
        $r.HasDrift | Should -BeTrue
        ($r.DriftDetails -join ' ') | Should -Match "carries no 'declared_states'"
        ($r.DriftDetails -join ' ') | Should -Match "carries no 'lens_body_floor'"
    }

    It 'INDUCED (empty-pinned-file class): a zero-byte pinned file FAILS instead of crashing' {
        $t = script:New-ScratchTree -Mutate {
            param($c)
            $c.Manifest.in_file_pins += [ordered]@{ surface = 'skills/demo-skill/references/demo-exhibit.md'; scope = 'file'; must_contain = @('Demo exhibit') }
        }
        Set-Content -LiteralPath (Join-Path $t.Dir 'skills/demo-skill/references/demo-exhibit.md') -Value '' -NoNewline -Encoding utf8
        $r = Get-LessonPromotionAudit -RepoRoot $t.Dir -ManifestPath $t.ManifestPath -ExpectedRosterCount 2 -ExpectedPromotedByChunk @{ '1' = 1 } -ReceivingSkillDirs @('skills/demo-skill')
        $r.HasDrift | Should -BeTrue
        ($r.DriftDetails -join ' ') | Should -Match 'names a file with no content'
    }

    It 'INDUCED (missing-in-file-pin class): the authoritative-source pin deleted from a lens section FAILS' {
        $r = script:Invoke-ScratchAudit {
            param($c)
            $body = Get-Content -LiteralPath $c.SkillPath -Raw -Encoding utf8
            Set-Content -LiteralPath $c.SkillPath -Encoding utf8 -Value ($body -replace '> \*\*Authoritative source\*\*[^\r\n]*\r?\n', '')
        }
        $r.HasDrift | Should -BeTrue
        ($r.DriftDetails -join ' ') | Should -Match "in-file pin on 'skills/demo-skill/SKILL.md' is missing its required text"
    }

    It 'INDUCED (unpinned-lens-home class): a lens in a skill with no in_file_pins row FAILS' {
        $r = script:Invoke-ScratchAudit { param($c) $c.Manifest.in_file_pins[0].surface = 'agents/Demo.agent.md' }
        $r.HasDrift | Should -BeTrue
        ($r.DriftDetails -join ' ') | Should -Match 'carries no in_file_pins row'
    }

    It 'INDUCED (missing-manifest class): an absent manifest FAILS instead of reading as nothing to check' {
        $t = script:New-ScratchTree
        Remove-Item -LiteralPath $t.ManifestPath -Force
        $r = Get-LessonPromotionAudit -RepoRoot $t.Dir -ManifestPath $t.ManifestPath -ReceivingSkillDirs @('skills/demo-skill')
        $r.HasDrift | Should -BeTrue
        ($r.DriftDetails -join ' ') | Should -Match 'manifest not found'
    }

    It 'INDUCED (unparseable-manifest class): malformed JSON FAILS' {
        $t = script:New-ScratchTree
        Set-Content -LiteralPath $t.ManifestPath -Encoding utf8 -Value '{ "entries": [ '
        $r = Get-LessonPromotionAudit -RepoRoot $t.Dir -ManifestPath $t.ManifestPath -ReceivingSkillDirs @('skills/demo-skill')
        $r.HasDrift | Should -BeTrue
        ($r.DriftDetails -join ' ') | Should -Match 'did not parse'
    }

    It 'INDUCED (fallback-population class): omitting the caller-supplied receiving set is itself reported' {
        # Silence would be the worst outcome: the weaker manifest-derived population would run and
        # nothing would say the guard had been narrowed.
        $t = script:New-ScratchTree
        $r = Get-LessonPromotionAudit -RepoRoot $t.Dir -ManifestPath $t.ManifestPath -ExpectedRosterCount 2 -ExpectedPromotedByChunk @{ '1' = 1 }
        ($r.DriftDetails -join ' ') | Should -Match 'no caller-supplied receiving-skill set'
    }

    It 'POSITIVE CONTROL: the unmutated fixture reports clean' {
        # Without this, every assertion above is satisfied by a function returning HasDrift = $true
        # for all inputs.
        $r = script:Invoke-ScratchAudit
        $r.DriftDetails -join ' | ' | Should -BeExactly ''
        $r.HasDrift | Should -BeFalse
        $r.PromotedCount | Should -Be 1
        $r.PendingCount | Should -Be 1
    }
}

Describe 'Lesson promotion: properties that do not rot' {

    It 'the manifest names the suite that enforces it, so a red has a local explanation' {
        $m = Get-Content -LiteralPath $script:ManifestPath -Raw -Encoding utf8 | ConvertFrom-Json
        [string]$m.authoritative_check | Should -BeExactly '.github/scripts/Tests/lesson-promotion-manifest.Tests.ps1'
        [string]$m.rename_migration | Should -Match 'migration, not a regression'
    }

    It 'a section read stops at the next heading of the same or higher level' {
        $t = script:New-ScratchTree
        $sec = Get-LPSection -Path $t.SkillPath -Anchor '#### A demo lens that carries its own actionable core'
        $sec.Text | Should -Match 'The core sentence a reader has to reach'
        $sec.Text | Should -Not -Match 'collects the traps'
        Get-LPSection -Path $t.SkillPath -Anchor '#### No such heading' | Should -BeNullOrEmpty
    }

    It 'a description parses into a use clause and an exclusion clause that do not overlap' {
        $t = script:New-ScratchTree
        $d = Get-LPSkillDescription -Path $t.SkillPath
        $d.UseClause | Should -Match 'reconciling a promoted roster'
        $d.UseClause | Should -Not -Match 'DO NOT USE FOR'
        $d.Exclusion | Should -Match 'DO NOT USE FOR'
        $d.Unsupported | Should -BeNullOrEmpty
    }

    It 'a nested description key does not win over the top-level one, and a block scalar says so' {
        $t = script:New-ScratchTree -Mutate {
            param($c)
            $body = Get-Content -LiteralPath $c.SkillPath -Raw -Encoding utf8
            Set-Content -LiteralPath $c.SkillPath -Encoding utf8 -Value ($body -replace '(?m)^name: demo-skill$', "name: demo-skill`nmeta:`n  description: a nested key that must not win")
        }
        (Get-LPSkillDescription -Path $t.SkillPath).UseClause | Should -Match 'reconciling a promoted roster'

        $t2 = script:New-ScratchTree -Mutate {
            param($c)
            $body = Get-Content -LiteralPath $c.SkillPath -Raw -Encoding utf8
            Set-Content -LiteralPath $c.SkillPath -Encoding utf8 -Value ($body -replace '(?m)^description: ".*"$', "description: >-`n  a folded scalar this reader does not support")
        }
        (Get-LPSkillDescription -Path $t2.SkillPath).Unsupported | Should -Match 'block or folded scalar'
    }

    It 'the specificity floor has two independently-checked components' {
        # Deliberately NOT a pinned threshold value - a pinned number trains the next author to
        # edit the number rather than read the guard. What is pinned is that both components exist
        # and that each is capable of failing on its own.
        (Test-LPSpecificityFloor -Text 'roster work' -MinLength 24 -MinContentWords 3).Count | Should -BeGreaterThan 0
        (Test-LPSpecificityFloor -Text 'when they have been about that which they were' -MinLength 24 -MinContentWords 3).Count | Should -BeGreaterThan 0
        (Test-LPSpecificityFloor -Text 'reconciling a promoted roster against its receiving surfaces' -MinLength 24 -MinContentWords 3).Count | Should -Be 0
    }

    It 'trigger text that wraps across a source line break still matches' {
        # Get-LPSection joins with LF and a manifest string cannot express one, so an exact-ordinal
        # match alone would make a correct trigger unmatchable for a reason no author could see.
        (Test-LPContains -Haystack "the trigger phrase`nspans two lines" -Needle 'the trigger phrase spans two lines') | Should -BeTrue
        (Test-LPContains -Haystack 'nothing like it here' -Needle 'the trigger phrase spans two lines') | Should -BeFalse
    }
}
