#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    Contract tests for the /open surface (issue #974, chunk 3 of #957).

.DESCRIPTION
    Pins the four properties of this chunk that no other suite observes:

      1. The entrance has NO natural-language routing intent, checked by a
         probe carrying its own positive control. This cannot ride the
         general nl-intent-routing run: that suite's only per-entry loop
         asserts each declared intent resolves to an existing command file,
         so once commands/open.md exists an added /open intent makes it
         PASS. The absence needs a check that could have come out positive.

      2. The open-for-work-affirmed marker family is registered, is
         post-new (never upsert), and was APPENDED rather than inserted --
         the two positional fixtures in persist-marker-core.Tests.ps1 still
         select the families they selected before this row existed.

      3. The command and skill exist, the command halts rather than
         improvising when the methodology cannot be loaded, and the skill
         reaches beat 2, the floor, the escape hatch, and both outputs.

      4. post-pr-review names the close-out record at close time, scoped to
         issues that ran this flow, pointing at the existing ledger rather
         than re-emitting it.

    The affirmation gate's register entries and its skill-side rule block
    are pinned by engagement-gate-non-overridability.Tests.ps1, which owns
    the bounded-clause contract for every registered gate.
#>

Describe 'open-for-work surface (issue #974)' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path

        $script:ReadRepoFile = {
            param([string]$RelativePath)
            $path = Join-Path $script:RepoRoot $RelativePath
            if (-not (Test-Path -LiteralPath $path)) { return '' }
            return (Get-Content -LiteralPath $path -Raw) -replace "`r`n?", "`n"
        }

        # The probe under test: given a routing table, return every entry
        # that would route a request to the open-for-work entrance. Written
        # to take the table as an argument precisely so it can be aimed at a
        # synthetic table that DOES contain such an entry.
        $script:FindEntranceIntents = {
            param([object]$RoutingTable)

            $entries = @()
            if ($null -eq $RoutingTable) { return $entries }
            $nl = $RoutingTable.nl_intent_routing
            if ($null -eq $nl -or $null -eq $nl.entries) { return $entries }

            foreach ($entry in @($nl.entries)) {
                $commands = @($entry.claude_command, $entry.copilot_command) | Where-Object { $_ }
                foreach ($command in $commands) {
                    if ($command.TrimStart('/') -eq 'open') { $entries += $entry; break }
                }
            }
            return $entries
        }

        $script:LiveRoutingConfig = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'skills/routing-tables/assets/routing-config.json') -Raw |
            ConvertFrom-Json
    }

    Context 'no natural-language routing intent for the entrance (criterion 10)' {

        It 'the probe finds a deliberately planted /open intent (positive control)' {
            # Same shape as the live table, plus one entry that must be
            # caught. If this fails, the negative assertion below proves
            # nothing.
            $planted = @{
                nl_intent_routing = @{
                    source  = 'synthetic-positive-control'
                    entries = @(
                        [pscustomobject]@{
                            intent_key      = 'review-local'
                            patterns        = @('review this')
                            claude_command  = '/orchestra:review'
                            copilot_command = '/review'
                        },
                        [pscustomobject]@{
                            intent_key      = 'open-for-work'
                            patterns        = @("let's work on #?\d+", 'pick up #?\d+')
                            claude_command  = '/open'
                            copilot_command = $null
                        }
                    )
                }
            } | ConvertTo-Json -Depth 6 | ConvertFrom-Json

            $hits = @(& $script:FindEntranceIntents $planted)
            $hits.Count | Should -Be 1 -Because 'the probe must be able to detect an entrance routing intent at all'
            $hits[0].intent_key | Should -Be 'open-for-work'
        }

        It 'the live routing table declares no intent that routes to the entrance' {
            $hits = @(& $script:FindEntranceIntents $script:LiveRoutingConfig)
            $intentKeys = ($hits | ForEach-Object { $_.intent_key }) -join ', '
            $hits.Count | Should -Be 0 -Because "the entrance is explicit-invocation only (#957 D9, Amendment 5): a bare pickup must not silently enter a flow whose first act is an engagement gate. Offending intents: $intentKeys"
        }

        It 'the live routing table is non-empty, so the negative result is not vacuous' {
            @($script:LiveRoutingConfig.nl_intent_routing.entries).Count |
                Should -BeGreaterThan 0 -Because 'an empty table would make the absence assertion above trivially true'
        }
    }

    Context 'the open-for-work-affirmed marker family (criterion 2)' {

        BeforeAll {
            . (Join-Path $script:RepoRoot '.github/scripts/lib/marker-transport-core.ps1')
            . (Join-Path $script:RepoRoot '.github/scripts/lib/frame-engagement-record-core.ps1')
            . (Join-Path $script:RepoRoot '.github/scripts/lib/frame-spine-core.ps1')
            . (Join-Path $script:RepoRoot 'skills/session-memory-contract/scripts/persist-marker-core.ps1')
            $script:Registry = @(Get-MarkerFamilyRegistry)
        }

        It 'is registered as a post-new issue-surface family' {
            $row = @($script:Registry | Where-Object { $_.Family -eq 'open-for-work-affirmed' })
            $row.Count | Should -Be 1 -Because 'the affirmation record has exactly one registry row'
            $row[0].TargetSurface | Should -Be 'issue'
            $row[0].WriteShape | Should -Be 'post-new' -Because 'upsert PATCHes in place, which voids the record as an ordering witness, breaks the escape hatch''s new-record rule, and destroys the re-route count derived by counting records'
            $row[0].MarkerTemplate | Should -Be ('<' + '!-- open-for-work-affirmed-{ID} -->') -Because 'the catalog drift guard recognizes only -{ID}/-{PR} and silently skips any other placeholder token'
        }

        It 'was appended, not inserted: both positional fixtures still select their pre-#974 families' {
            # persist-marker-core.Tests.ps1:250 binds $script:PostNewFamily to
            # the FIRST post-new/issue row and :527 binds $issueOnlyFamily to
            # the FIRST issue-surface row. open-for-work-affirmed is
            # post-new/issue with a null adapter and null post-step -- the
            # exact shape those fixtures select -- so an inserted row would
            # re-point roughly two dozen generic write-path assertions at it
            # while every one of them still passed.
            @($script:Registry | Where-Object { $_.WriteShape -eq 'post-new' -and $_.TargetSurface -eq 'issue' })[0].Family |
                Should -Be 'design-phase-complete'
            @($script:Registry | Where-Object { $_.TargetSurface -eq 'issue' })[0].Family |
                Should -Be 'plan-issue'
        }

        # The live accept/refuse behavior of the write primitive is checked
        # out-of-suite against the real script (this chunk's criterion-2
        # evidence): a suite test that called Invoke-PersistMarkerWrite
        # would issue a network write once the registry preflight passes,
        # which is exactly the stage this row changes.

        It 'is discoverable from the documented catalog, not only from the script' {
            $catalog = & $script:ReadRepoFile 'skills/session-memory-contract/references/handoff-markers.md'
            $catalog | Should -Match ([regex]::Escape('(family `open-for-work-affirmed`, `post-new`)')) `
                -Because 'the catalog is the surface CLAUDE.md points readers at, and the runtime never reads it'
            $catalog | Should -Match ([regex]::Escape('Open-for-work affirmation (interim form, issue 957 Amendment 8) - issue {N}')) `
                -Because 'a resume must be able to recognise interim-form records from the catalog alone'
        }
    }

    Context 'the entrance command and its methodology (criteria 1, 8, 9)' {

        BeforeAll {
            $script:CommandText = & $script:ReadRepoFile 'commands/open.md'
            $script:SkillText   = & $script:ReadRepoFile 'skills/open-for-work/SKILL.md'
        }

        It 'the command exists and loads the methodology skill' {
            $script:CommandText | Should -Not -BeNullOrEmpty
            $script:CommandText | Should -Match ([regex]::Escape('skills/open-for-work/SKILL.md'))
        }

        It 'the command halts on a failed methodology load instead of improvising one' {
            $script:CommandText | Should -Match ([regex]::Escape('Skill load failed for skills/open-for-work/SKILL.md')) `
                -Because 'the halt message must be exact enough for an operator to recognise'
            $script:CommandText | Should -Match '(?i)cannot continue without the canonical methodology'
            $script:CommandText | Should -Match '(?i)do not improvise the flow'
        }

        It 'the skill reaches past beat 1 — the floor, beat 2, the escape hatch, and both outputs' {
            # Criteria 8 and 9 exist because a skill carrying only the
            # worth-it check and beat 1 would have satisfied the first
            # draft's criteria while shipping a flow that could not route,
            # floor, or produce either output.
            $script:SkillText | Should -Match '(?i)trivial floor'
            $script:SkillText | Should -Match '(?i)permission, authentication, or data-integrity behavior is never below the floor'
            $script:SkillText | Should -Match '(?i)fails closed'
            $script:SkillText | Should -Match '(?i)beat 2'
            $script:SkillText | Should -Match '(?i)escape hatch'
            $script:SkillText | Should -Match '(?i)routine arm'
            $script:SkillText | Should -Match '(?i)novel arm'
        }

        It 'the skill fixes each gate-decision token field rather than only instructing emission' {
            $script:SkillText | Should -Match ([regex]::Escape('phase: experience'))
            $script:SkillText | Should -Match ([regex]::Escape('open-for-work-affirmation'))
            $script:SkillText | Should -Match ([regex]::Escape('open-for-work-brief-approval'))
            $script:SkillText | Should -Match ([regex]::Escape('pre-ask'))
        }

        It 'the skill tells a resume to read comments from a source carrying updated_at' {
            $script:SkillText | Should -Match ([regex]::Escape('gh api repos/{owner}/{repo}/issues/{N}/comments')) `
                -Because 'gh issue view --json comments carries includesCreatedEdit and no updated_at, so the void-if-edited rule cannot be evaluated from it'
            $script:SkillText | Should -Match '(?i)affirmed-not-routed'
        }
    }

    Context 'the close-out record''s close-time reader (criterion 7)' {

        BeforeAll {
            $script:PostPrText = & $script:ReadRepoFile 'skills/post-pr-review/SKILL.md'
        }

        It 'the close-time checklist carries the close-out record step' {
            $script:PostPrText | Should -Match '(?m)^### 9\. Close-Out Record'
            $script:PostPrText | Should -Match '(?i)dead-premises note'
            $script:PostPrText | Should -Match '(?i)re-route count'
        }

        It 'the step is scoped to issues that ran the flow' {
            $script:PostPrText | Should -Match '(?i)affirmation record'
            $script:PostPrText | Should -Match '(?i)does not apply otherwise' `
                -Because 'an unconditional instruction turns every unrelated close into a demand for a beat-2 re-route count'
        }

        It 'the step points at the existing ledger rather than emitting one' {
            $script:PostPrText | Should -Match '(?i)does not emit ledger blocks'
        }

        It 'the completion section routes to the step, so the walk does not terminate before it' {
            # The close-time path continues past ## Completion into
            # ## Structured Outcome Contract; the walk must reach Step 9
            # from the checklist and be re-pointed at it from Completion.
            $completion = [regex]::Match($script:PostPrText, '(?ms)^## Completion\s*\n(?<body>.*?)(?=^## |\z)')
            $completion.Success | Should -BeTrue
            $completion.Groups['body'].Value | Should -Match '(?i)close-out record'
        }
    }
}
