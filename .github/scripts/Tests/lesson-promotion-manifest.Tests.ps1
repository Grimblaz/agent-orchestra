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
                clears a specificity floor, and a body trigger inside a named anchor;
      reverse - every file in a receiving references/ directory has a manifest row.

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
    $script:Live = Get-LessonPromotionAudit -RepoRoot $script:RepoRoot -ManifestPath $script:ManifestPath

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
                    home     = 'skills/demo-skill/SKILL.md'
                    anchor   = '#### A demo lens that carries its own actionable core'
                    triggers = @(
                        [ordered]@{ surface = 'skills/demo-skill/SKILL.md'; surface_kind = 'description'; text = 'reconciling a promoted roster against its receiving surfaces' },
                        [ordered]@{ surface = 'skills/demo-skill/SKILL.md'; surface_kind = 'body'; anchor = '#### A demo lens that carries its own actionable core'; text = 'The core sentence a reader has to reach in this section' }
                    )
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
        return Get-LessonPromotionAudit -RepoRoot $t.Dir -ManifestPath $t.ManifestPath
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
        $script:Live.Entries.Count | Should -BeGreaterThan 0
        $script:Live.PromotedCount | Should -BeGreaterThan 0
    }

    It 'every roster entry is in a declared state, and the count anchor agrees with the roster' {
        $m = Get-Content -LiteralPath $script:ManifestPath -Raw -Encoding utf8 | ConvertFrom-Json
        $declared = @($m.declared_states)
        foreach ($e in @($m.entries)) {
            $declared | Should -Contain ([string]$e.state) -Because "$($e.lesson) must be in a declared state"
        }
        @($m.entries).Count | Should -Be ([int]$m.roster_snapshot.count)
    }

    It 'every promoted lens home is a loading surface, read from the home path rather than the kind field' {
        # AC4 independence: this reads the recorded home and asserts its TYPE from the path, so it
        # does not pass merely because the fixture mutations below show the check would go red.
        $m = Get-Content -LiteralPath $script:ManifestPath -Raw -Encoding utf8 | ConvertFrom-Json
        foreach ($e in @($m.entries | Where-Object { $_.state -eq 'promoted' -and $_.kind -eq 'lens' })) {
            [string]$e.home | Should -Not -Match '/references/' -Because "$($e.lesson) is a lens, so its home must load"
            ([string]$e.home -match '^skills/[^/]+/SKILL\.md$' -or [string]$e.home -match '^agents/[^/]+\.agent\.md$') |
                Should -BeTrue -Because "$($e.lesson) names home $($e.home), which is not a skill or agent body"
            (Test-Path -LiteralPath (Join-Path $script:RepoRoot ([string]$e.home))) | Should -BeTrue
        }
    }

    It 'is itself selected by CI, so the guard cannot be dropped without dropping what would report it' {
        . (Join-Path $script:RepoRoot '.github/scripts/lib/ci-suite-selection-core.ps1')
        $sel = Get-CISuiteSelection -TestsRoot (Join-Path $script:RepoRoot '.github/scripts/Tests') -QuarantinePath (Join-Path $script:RepoRoot '.github/scripts/Tests/ci-quarantine.json')
        $sel.SelectedNames | Should -Contain 'lesson-promotion-manifest.Tests.ps1'
    }
}

Describe 'Lesson promotion: one induced failure per class the guard claims to catch' {

    It 'INDUCED (no-declared-state class): a roster entry in no declared state FAILS' {
        $r = script:Invoke-ScratchAudit { param($c) $c.Manifest.entries[0].state = 'half-done' }
        $r.HasDrift | Should -BeTrue
        ($r.DriftDetails -join ' ') | Should -Match 'is in no declared state'
    }

    It 'INDUCED (roster-truncation class): a lesson removed from the roster FAILS on the count anchor' {
        $r = script:Invoke-ScratchAudit { param($c) $c.Manifest.entries = @($c.Manifest.entries[0]) }
        $r.HasDrift | Should -BeTrue
        ($r.DriftDetails -join ' ') | Should -Match 'roster count anchor says 2'
    }

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
        # Distinct from the description class and from the anchor class: the heading survives and
        # the condition survives; only the lens's own core sentence is gone.
        $r = script:Invoke-ScratchAudit {
            param($c)
            $body = Get-Content -LiteralPath $c.SkillPath -Raw -Encoding utf8
            Set-Content -LiteralPath $c.SkillPath -Encoding utf8 -Value ($body -replace 'The core sentence a reader has to reach in this section\.', 'See the promotion manifest.')
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
        # The layer-4 half. A rename here breaks subagent reach while every skill-side assertion
        # stays green, which is exactly why it is asserted separately from the body class.
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

    It 'INDUCED (neutering-by-relocation class): a trigger moved into the DO NOT USE FOR clause FAILS' {
        # The trigger text is still present to a naive substring search. It now reads to a consumer
        # as a reason NOT to load the skill, which is the opposite of a trigger.
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
        # Asserted separately from the length component: a floor enforcing only length is cleared
        # by padding, and a floor enforcing only content words is cleared by two rare words.
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
        $r = script:Invoke-ScratchAudit {
            param($c)
            $c.Manifest.entries[0].triggers[1].anchor = ''
        }
        $r.HasDrift | Should -BeTrue
        ($r.DriftDetails -join ' ') | Should -Match 'scoped to the whole file rather than to a named anchor'
    }

    It 'INDUCED (lens-floor class): a lens whose home is a non-loading surface FAILS' {
        # The disguised demotion. Recorded as promoted, parked somewhere nothing loads.
        $r = script:Invoke-ScratchAudit {
            param($c)
            $c.Manifest.entries[0].home = 'skills/demo-skill/references/demo-exhibit.md'
            $c.Manifest.entries[0].anchor = '# Demo exhibit'
            $c.Manifest.entries[0].triggers[1].surface = 'skills/demo-skill/references/demo-exhibit.md'
            $c.Manifest.entries[0].triggers[1].anchor = '# Demo exhibit'
        }
        $r.HasDrift | Should -BeTrue
        ($r.DriftDetails -join ' ') | Should -Match 'is a references file, which is not a loading surface'
    }

    It 'INDUCED (orphan-exhibit class): an exhibit no surface cites FAILS' {
        $r = script:Invoke-ScratchAudit {
            param($c)
            $body = Get-Content -LiteralPath $c.SkillPath -Raw -Encoding utf8
            Set-Content -LiteralPath $c.SkillPath -Encoding utf8 -Value ($body -replace '\[`references/demo-exhibit\.md`\]\(references/demo-exhibit\.md\) collects the traps\.', 'Traps are collected elsewhere.')
        }
        $r.HasDrift | Should -BeTrue
        ($r.DriftDetails -join ' ') | Should -Match "points at a section that never mentions 'demo-exhibit.md'"
    }

    It 'INDUCED (unmanifested-references-file class): a references file with no manifest row FAILS' {
        $r = script:Invoke-ScratchAudit {
            param($c)
            Set-Content -LiteralPath (Join-Path $c.Dir 'skills/demo-skill/references/stowaway.md') -Encoding utf8 -Value '# Stowaway'
        }
        $r.HasDrift | Should -BeTrue
        ($r.DriftDetails -join ' ') | Should -Match "'skills/demo-skill/references/stowaway.md' sits in a receiving references directory with no manifest row"
    }

    It 'INDUCED (forward-citation class): a lens citing an exhibit no manifest row carries FAILS' {
        # The cross-chunk dead end: exhibits arrive a chunk later, and the citation is broken for
        # as long as that chunk is deferred.
        $r = script:Invoke-ScratchAudit {
            param($c)
            $body = Get-Content -LiteralPath $c.SkillPath -Raw -Encoding utf8
            Set-Content -LiteralPath $c.SkillPath -Encoding utf8 -Value ($body -replace 'The core sentence a reader has to reach in this section\.', 'The core sentence a reader has to reach in this section. See references/not-yet-shipped.md.')
        }
        $r.HasDrift | Should -BeTrue
        ($r.DriftDetails -join ' ') | Should -Match "cites 'references/not-yet-shipped.md', which no manifest exhibit row carries"
    }

    It 'INDUCED (exhibit-only-promotion class): a promoted roster entry re-labelled kind=exhibit FAILS' {
        # The third GREEN the delivery mutation campaign returned. Every kind-conditional assertion
        # was blind to it: relabel the entry and the lens clauses simply stop applying, so the
        # lesson counts as promoted while being recorded as non-firing content. That is accepted
        # recall loss wearing a promotion's label, and the lens floor forbids it.
        $r = script:Invoke-ScratchAudit { param($c) $c.Manifest.entries[0].kind = 'exhibit' }
        $r.HasDrift | Should -BeTrue
        ($r.DriftDetails -join ' ') | Should -Match "only promoted kind is 'lens'"
    }

    It 'INDUCED (pointer-lens class): a lens gutted to a pointer, keeping its pinned trigger, FAILS' {
        # Found by the delivery mutation campaign as a GREEN probe against an earlier revision of
        # this guard, and recorded as a finding about the check rather than dropped. The trigger
        # sentence survives inside the gutted section, so every trigger assertion stays green while
        # the lesson's core is gone - which is the disguised demotion the lens floor forbids.
        $r = script:Invoke-ScratchAudit {
            param($c)
            $body = Get-Content -LiteralPath $c.SkillPath -Raw -Encoding utf8
            $body = $body -replace '(?s)(#### A demo lens that carries its own actionable core\r?\n\r?\n).*?(\r?\n\r?\n## Traps)',
                                   '$1See the promotion manifest. The core sentence a reader has to reach in this section.$2'
            Set-Content -LiteralPath $c.SkillPath -Encoding utf8 -Value $body
        }
        $r.HasDrift | Should -BeTrue
        ($r.DriftDetails -join ' ') | Should -Match 'below the lens-body floor'
        ($r.DriftDetails -join ' ') | Should -Match 'a pointer, not the lesson'
    }

    It 'INDUCED (missing-in-file-pin class): the authoritative-source pin deleted from a lens section FAILS' {
        # Also a GREEN probe against an earlier revision: the pin and the rename-migration note were
        # prose nothing held, which is precisely the delivery-demo-is-not-a-guard failure one of the
        # promoted lessons describes.
        $r = script:Invoke-ScratchAudit {
            param($c)
            $body = Get-Content -LiteralPath $c.SkillPath -Raw -Encoding utf8
            Set-Content -LiteralPath $c.SkillPath -Encoding utf8 -Value ($body -replace '> \*\*Authoritative source\*\*[^\r\n]*\r?\n', '')
        }
        $r.HasDrift | Should -BeTrue
        ($r.DriftDetails -join ' ') | Should -Match "in-file pin on 'skills/demo-skill/SKILL.md' is missing its required text"
    }

    It 'INDUCED (missing-manifest class): an absent manifest FAILS instead of reading as nothing to check' {
        $t = script:New-ScratchTree
        Remove-Item -LiteralPath $t.ManifestPath -Force
        $r = Get-LessonPromotionAudit -RepoRoot $t.Dir -ManifestPath $t.ManifestPath
        $r.HasDrift | Should -BeTrue
        ($r.DriftDetails -join ' ') | Should -Match 'manifest not found'
    }

    It 'INDUCED (unparseable-manifest class): malformed JSON FAILS' {
        $t = script:New-ScratchTree
        Set-Content -LiteralPath $t.ManifestPath -Encoding utf8 -Value '{ "entries": [ '
        $r = Get-LessonPromotionAudit -RepoRoot $t.Dir -ManifestPath $t.ManifestPath
        $r.HasDrift | Should -BeTrue
        ($r.DriftDetails -join ' ') | Should -Match 'did not parse'
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

    It 'the specificity floor has two independently-checked components' {
        # Deliberately NOT a pinned threshold value - a pinned number trains the next author to
        # edit the number rather than read the guard. What is pinned is that both components exist
        # and that each is capable of failing on its own.
        $m = Get-Content -LiteralPath $script:ManifestPath -Raw -Encoding utf8 | ConvertFrom-Json
        [int]$m.specificity_floor.min_length | Should -BeGreaterThan 0
        [int]$m.specificity_floor.min_content_words | Should -BeGreaterThan 0

        (Test-LPSpecificityFloor -Text 'roster work' -MinLength 24 -MinContentWords 3).Count | Should -BeGreaterThan 0
        (Test-LPSpecificityFloor -Text 'when they have been about that which they were' -MinLength 24 -MinContentWords 3).Count | Should -BeGreaterThan 0
        (Test-LPSpecificityFloor -Text 'reconciling a promoted roster against its receiving surfaces' -MinLength 24 -MinContentWords 3).Count | Should -Be 0
    }

    It 'a section read stops at the next heading of the same or higher level' {
        # The property that makes a body trigger scoped rather than file-wide. Without it, text
        # anywhere in the file satisfies an anchor-scoped trigger.
        $t = script:New-ScratchTree
        $section = Get-LPSection -Path $t.SkillPath -Anchor '#### A demo lens that carries its own actionable core'
        $section | Should -Match 'The core sentence a reader has to reach'
        $section | Should -Not -Match 'collects the traps'
        Get-LPSection -Path $t.SkillPath -Anchor '#### No such heading' | Should -BeNullOrEmpty
    }

    It 'a description parses into a use clause and an exclusion clause that do not overlap' {
        $t = script:New-ScratchTree
        $d = Get-LPSkillDescription -Path $t.SkillPath
        $d.UseClause | Should -Match 'reconciling a promoted roster'
        $d.UseClause | Should -Not -Match 'DO NOT USE FOR'
        $d.Exclusion | Should -Match 'DO NOT USE FOR'
    }

    It 'every promoted entry records a contradiction verdict against the doctrine surfaces it was checked on' {
        $m = Get-Content -LiteralPath $script:ManifestPath -Raw -Encoding utf8 | ConvertFrom-Json
        foreach ($e in @($m.entries | Where-Object { $_.state -eq 'promoted' })) {
            @('clean', 'cite', 'contradiction') | Should -Contain ([string]$e.checked_against.verdict) -Because "$($e.lesson) needs a verdict"
            @($e.checked_against.surfaces).Count | Should -BeGreaterThan 0
            [string]$e.checked_against.note | Should -Not -BeNullOrEmpty
        }
    }

    It 'a lesson already stated in shipped doctrine is promoted as a citing lens, not a restatement' {
        # An all-clean verdict set would mean the contradiction check never searched. This asserts
        # the population is non-empty in BOTH directions rather than pinning which lessons are in it.
        $m = Get-Content -LiteralPath $script:ManifestPath -Raw -Encoding utf8 | ConvertFrom-Json
        $promoted = @($m.entries | Where-Object { $_.state -eq 'promoted' })
        @($promoted | Where-Object { $_.checked_against.verdict -eq 'cite' }).Count | Should -BeGreaterThan 0
        @($promoted | Where-Object { $_.checked_against.verdict -eq 'clean' }).Count | Should -BeGreaterThan 0
        @($promoted | Where-Object { $_.checked_against.verdict -eq 'contradiction' }).Count | Should -Be 0 -Because 'a contradicting lesson does not ship - it routes up'
    }
}
