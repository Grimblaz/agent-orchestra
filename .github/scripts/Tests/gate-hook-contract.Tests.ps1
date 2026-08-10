#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
.SYNOPSIS
    Contract tests locking the gate event-log infrastructure.

.DESCRIPTION
    Mostly file-content assertions. Locks:
      - Resolve-GateSessionKey resolvable from its own home, and absent from the retired hook
      - Gate-decision-token JSON schema presence and structure
      - Root hooks.json and hooks/hooks.json carry no gate-event PostToolUse matcher
      - gate-reconciliation-core.ps1 lib presence and interface contracts

    Issue #1003 retired the L1 `PostToolUse` gate-event logger: a hook keyed to one
    presentation mechanism has no reliable trigger once the repository specifies no
    mechanism for surfacing a decision. The four hook-specific assertions in this
    suite were re-pointed rather than deleted — three now assert the retirement held,
    and the fourth follows `Resolve-GateSessionKey` to its new home. The eight
    non-hook assertions (schema, #556 regression guard, reconciler library) are
    unchanged and must keep passing.
#>

Describe 'gate session key relocation contract — issue #1003' {

    BeforeAll {
        $script:RepoRoot   = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:KeyLibPath = Join-Path $script:RepoRoot 'skills/solution-authoring/scripts/Resolve-GateSessionKey.ps1'
        $script:RetiredHook = Join-Path $script:RepoRoot 'skills/solution-authoring/scripts/gate-event-logger-hook.ps1'

        if (Test-Path $script:KeyLibPath) { . $script:KeyLibPath }
    }

    It 'the retired L1 hook script is gone' {
        $script:RetiredHook | Should -Not -Exist `
            -Because 'issue #1003 retired the PostToolUse gate-event logger'
    }

    It 'Resolve-GateSessionKey resolves from its new home and returns a non-empty key' {
        $script:KeyLibPath | Should -Exist `
            -Because 'the four L0 writers interpolate {session_key} and need the derivation reachable without the retired producer'

        # Invoke it, do not merely match its name: a name in a comment pins nothing.
        # Dot-source + in-process call, per script-safety-contract.Tests.ps1 (#257).
        Get-Command Resolve-GateSessionKey -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty `
            -Because 'dot-sourcing the relocated helper must define the function'

        Resolve-GateSessionKey -SessionId 'contract/test 1' | Should -Be 's-contract-test-1' `
            -Because 'the session-id branch sanitizes to s-{slug}'
    }

    It 'Resolve-GateSessionKey falls back to a key when no session id is supplied' {
        Resolve-GateSessionKey | Should -Match '^(b-|sha-|session$)' `
            -Because 'the documented fallback order is branch-slug then short sha then the literal session'
    }
}

Describe 'gate-decision-token schema contract' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
    }

    It 'gate-decision-token schema exists' {
        Join-Path $script:RepoRoot 'skills/solution-authoring/schemas/gate-decision-token.schema.json' | Should -Exist
    }

    It 'schema declares outcome enum containing asked' {
        $schemaPath = Join-Path $script:RepoRoot 'skills/solution-authoring/schemas/gate-decision-token.schema.json'
        $schema = Get-Content $schemaPath -Raw | ConvertFrom-Json
        $outcomeEnum = $schema.properties.outcome.enum
        $outcomeEnum | Should -Not -BeNullOrEmpty
        $outcomeEnum | Should -Contain 'asked'
    }
}

Describe 'hooks.json gate-event matcher retirement contract' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
    }

    It 'hooks.json exists' {
        Join-Path $script:RepoRoot 'hooks.json' | Should -Exist
    }

    It 'hooks.json carries no gate-event PostToolUse matcher' {
        $hooksPath = Join-Path $script:RepoRoot 'hooks.json'
        $hooksContent = Get-Content $hooksPath -Raw | ConvertFrom-Json
        $postToolUseEntries = @($hooksContent.hooks.PostToolUse)
        $postToolUseEntries | Should -Not -BeNullOrEmpty `
            -Because 'the plugin-release-hygiene PostToolUse hook is unaffected by #1003 and must survive'
        $gateMatchers = @($postToolUseEntries | Where-Object { $_.matcher -match 'AskUserQuestion|askQuestions' })
        $gateMatchers.Count | Should -Be 0 `
            -Because 'issue #1003 retired the gate-event logger; re-adding its matcher would point at a deleted script'
    }
}

Describe 'hooks/hooks.json gate-event matcher retirement contract' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
    }

    It 'hooks/hooks.json exists' {
        Join-Path $script:RepoRoot 'hooks/hooks.json' | Should -Exist
    }

    It 'hooks/hooks.json carries no gate-event PostToolUse matcher' {
        $hooksPath = Join-Path $script:RepoRoot 'hooks/hooks.json'
        $hooksContent = Get-Content $hooksPath -Raw | ConvertFrom-Json
        $postToolUseEntries = @($hooksContent.hooks.PostToolUse)
        $postToolUseEntries | Should -Not -BeNullOrEmpty `
            -Because 'the plugin-release-hygiene PostToolUse hook is unaffected by #1003 and must survive'
        $gateMatchers = @($postToolUseEntries | Where-Object { $_.matcher -match 'AskUserQuestion|askQuestions' })
        $gateMatchers.Count | Should -Be 0 `
            -Because 'issue #1003 retired the gate-event logger; re-adding its matcher would point at a deleted script'
    }
}

Describe 'gate-decision-token schema regression guards — issue #556' {

    BeforeAll {
        $script:RepoRoot   = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:SchemaPath = Join-Path $script:RepoRoot 'skills/solution-authoring/schemas/gate-decision-token.schema.json'
        $script:Schema     = Get-Content $script:SchemaPath -Raw -ErrorAction Stop
    }

    # Regression guard: no brief_tier property added (additionalProperties: false already enforces this,
    # but this assertion makes intent explicit and detects if someone adds the property to properties{}).
    It 'schema does not contain a "brief_tier" top-level property (regression guard — must stay GREEN)' {
        $script:Schema | Should -Not -Match '"brief_tier"'
    }
}

Describe 'gate-reconciliation-core lib contract' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
    }

    It 'gate-reconciliation-core.ps1 exists' {
        Join-Path $script:RepoRoot '.github/scripts/lib/gate-reconciliation-core.ps1' | Should -Exist
    }

    It 'lib declares Read-GateTokens function' {
        $libPath = Join-Path $script:RepoRoot '.github/scripts/lib/gate-reconciliation-core.ps1'
        $content = Get-Content $libPath -Raw
        $content | Should -Match 'function Read-GateTokens'
    }

    It 'lib references frame-engagement-record-core.ps1' {
        $libPath = Join-Path $script:RepoRoot '.github/scripts/lib/gate-reconciliation-core.ps1'
        $content = Get-Content $libPath -Raw
        $content | Should -Match 'frame-engagement-record-core\.ps1'
    }
}
