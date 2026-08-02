#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    Contract tests for the adversarial-review core-vs-mode split and shared
    evidence packet (issue #975, workstreams B and C).

.DESCRIPTION
    Workstream C moved the per-mode workflow checklists out of the shared
    SKILL.md core into skills/adversarial-review/modes/*.md, loaded
    selector-conditionally so a Code-Critic dispatch boots only the methodology
    its selector names. These tests pin:

    - every selector in the routing table maps to exactly one mode file (or the
      documented no-mode-file CE case), and that mode file exists;
    - the moved workflow sections live in their mode files and no longer sit in
      the core, while the shared-core sections that other tests pin (evidence
      standards, atomic discipline) stay in the core;
    - the Code-Critic body load directive routes core + one mode file, not the
      whole catalog;
    - the shared evidence packet is defined once and placed inside the
      cache-shared prompt span (workstream B, AC1/AC2).
#>

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
    function script:RepoText([string]$rel) {
        Get-Content -LiteralPath (Join-Path $script:RepoRoot $rel) -Raw -ErrorAction Stop
    }

    $script:Core       = script:RepoText 'skills/adversarial-review/SKILL.md'
    $script:Body       = script:RepoText 'agents/Code-Critic.agent.md'
    $script:Dispatcher = script:RepoText 'skills/adversarial-review/platforms/claude.md'

    $script:ModeFiles = @{
        'code-prosecution'  = 'skills/adversarial-review/modes/code-prosecution.md'
        'design-review'     = 'skills/adversarial-review/modes/design-review.md'
        'defense'           = 'skills/adversarial-review/modes/defense.md'
        'proxy-prosecution' = 'skills/adversarial-review/modes/proxy-prosecution.md'
    }

    # Canonical selector set, read from routing-config rather than restated here,
    # so a selector added there without a loading-table row fails this file.
    $script:RoutingConfig = (script:RepoText 'skills/routing-tables/assets/routing-config.json') | ConvertFrom-Json
    $script:RoutingMarkers = @(
        $script:RoutingConfig.review_mode_routing.entries |
            Where-Object { $null -ne $_.marker } |
            ForEach-Object { [string]$_.marker }
    )

    # Selector -> the mode file a dispatch carrying it must boot. The CE selector
    # is the documented no-mode-file case (its contract is inline in the body).
    $script:ExpectedModeForMarker = @{
        'Use code review perspectives'          = 'code-prosecution'
        'Use lite code review perspectives'     = 'code-prosecution'
        'Use post-fix code review perspectives' = 'code-prosecution'
        'Use design review perspectives'        = 'design-review'
        'Use defense review perspectives'       = 'defense'
        'Score and represent GitHub review'     = 'proxy-prosecution'
        'Use CE review perspectives'            = $null
    }
}

Describe 'Mode-scoped loading — mode files exist and carry their workflow (C, AC3)' {
    It 'every declared mode file exists on disk' {
        foreach ($rel in $script:ModeFiles.Values) {
            Test-Path -LiteralPath (Join-Path $script:RepoRoot $rel) |
                Should -BeTrue -Because "$rel must exist for selector-conditional loading"
        }
    }

    It 'code-prosecution mode file carries the six-perspective Code Prosecution Workflow' {
        $t = script:RepoText $script:ModeFiles['code-prosecution']
        $t | Should -Match '## Code Prosecution Workflow'
        $t | Should -Match '### 6. Script And Automation'
        $t | Should -Match '### 7. Missed-gate detection'
    }

    It 'design-review mode file carries the Design Review skeleton' {
        $t = script:RepoText $script:ModeFiles['design-review']
        $t | Should -Match '## Design Review'
        $t | Should -Match '§D1'
        $t | Should -Match '§D3'
    }

    It 'defense mode file carries the Defense Workflow' {
        script:RepoText $script:ModeFiles['defense'] | Should -Match '## Defense Workflow'
    }

    It 'proxy-prosecution mode file carries the Proxy Prosecution Workflow' {
        script:RepoText $script:ModeFiles['proxy-prosecution'] | Should -Match '## Proxy Prosecution Workflow'
    }
}

Describe 'Mode-scoped loading — the core is scoped down but keeps shared content' {
    It 'core no longer carries the per-mode workflow checklists' {
        $script:Core | Should -Not -Match '## Code Prosecution Workflow' `
            -Because 'the code-prosecution checklist moved to modes/code-prosecution.md'
        $script:Core | Should -Not -Match '## Defense Workflow' `
            -Because 'the defense workflow moved to modes/defense.md'
        $script:Core | Should -Not -Match '## Proxy Prosecution Workflow' `
            -Because 'the proxy workflow moved to modes/proxy-prosecution.md'
        $script:Core | Should -Not -Match '(?m)^## Design Review\s*$' `
            -Because 'the design-review skeleton moved to modes/design-review.md; a re-added core section would double-load it for every mode'
    }

    It 'core keeps the shared sections other contracts pin' {
        $script:Core | Should -Match '### 2. Apply Evidence Standards'
        $script:Core | Should -Match '### 4. Emit a Usable Ledger'
        $script:Core | Should -Match '## Atomic Pipeline Discipline'
        $script:Core | Should -Match '## Mode-Scoped Loading'
    }

    It 'every routing-config selector resolves to a mode file (or the documented CE no-file case)' {
        $script:RoutingMarkers.Count | Should -BeGreaterThan 0 `
            -Because 'routing-config must expose the review_mode_routing marker set this check reads'

        foreach ($marker in $script:RoutingMarkers) {
            $script:ExpectedModeForMarker.ContainsKey($marker) | Should -BeTrue `
                -Because "routing-config selector '$marker' has no mode-file mapping — add it to modes/ and to the core Mode-Scoped Loading table, or record it as a no-mode-file case"

            $modeKey = $script:ExpectedModeForMarker[$marker]
            if ($null -eq $modeKey) { continue }   # CE: contract inline in the agent body

            Test-Path -LiteralPath (Join-Path $script:RepoRoot $script:ModeFiles[$modeKey]) |
                Should -BeTrue -Because "selector '$marker' maps to $modeKey, whose mode file must exist"
            $script:Core | Should -Match ([regex]::Escape($marker)) `
                -Because "the core Mode-Scoped Loading table must name selector '$marker'"
        }
    }

    It 'core Mode-Scoped Loading table names all four mode files plus the CE no-file case' {
        foreach ($rel in $script:ModeFiles.Values) {
            $leaf = ($rel -split '/')[-1]
            $script:Core | Should -Match ([regex]::Escape($leaf)) `
                -Because "the loading table must point at $leaf"
        }
        $script:Core | Should -Match '(?i)Use CE review perspectives' `
            -Because 'the CE case must be documented as the no-mode-file exception'
    }
}

Describe 'Mode-scoped loading — the body routes core + one mode file (C)' {
    It 'the Code-Critic body load directive names the core and the selector-to-mode-file mapping' {
        $script:Body | Should -Match 'Load `skills/adversarial-review/SKILL\.md`' `
            -Because 'the body must still load the shared core'
        $script:Body | Should -Match 'exactly the one mode file' `
            -Because 'the body must instruct loading a single mode file, not the whole catalog'
        $script:Body | Should -Match 'modes/code-prosecution\.md'
        $script:Body | Should -Match 'modes/design-review\.md'
    }
}

Describe 'Shared evidence packet — defined once, placed inside the shared span (B, AC1/AC2)' {
    It 'the dispatcher defines a Shared Evidence Packet section' {
        $script:Dispatcher | Should -Match '## Shared Evidence Packet'
    }

    It 'the packet is provenance-labeled and raw (#735)' {
        $script:Dispatcher | Should -Match '(?i)provenance-labeled'
        $script:Dispatcher | Should -Match '(?i)Do not summarize, filter, or re-word'
    }

    It 'the packet is placed before pass-specific lens material so same-model prompts share the prefix (AC1)' {
        $script:Dispatcher | Should -Match '(?is)packet goes \*\*after\*\*.{0,80}selector line, and \*\*before\*\* any pass-specific material'
        $script:Dispatcher | Should -Match '(?is)Pass-specific material comes \*\*last\*\*'
    }

    It 'the packet header carries the no-re-fetch directive but preserves beyond-packet investigation (AC2, falsifier c)' {
        $script:Dispatcher | Should -Match '(?is)must not re-fetch'
        $script:Dispatcher | Should -Match '(?is)Investigation \*beyond\* the packet remains expected'
    }

    It 'the standard prosecution bullet carries the packet before the role and lens material' {
        $script:Dispatcher | Should -Match '(?is)shared evidence packet.{0,80}pass-specific role and lens material \*\*last\*\*'
    }
}
