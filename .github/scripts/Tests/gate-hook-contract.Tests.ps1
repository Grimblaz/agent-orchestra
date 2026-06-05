#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
.SYNOPSIS
    Contract tests locking the gate hook infrastructure.

.DESCRIPTION
    Pure file-content assertions — no lib invocations. Locks:
      - Gate event logger hook script presence and content
      - Gate-decision-token JSON schema presence and structure
      - Root hooks.json PostToolUse AskUserQuestion matcher
      - hooks/hooks.json PostToolUse AskUserQuestion matcher
      - gate-reconciliation-core.ps1 lib presence and interface contracts
#>

Describe 'gate event logger hook contract' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
    }

    It 'hook script exists' {
        Join-Path $script:RepoRoot 'skills/solution-authoring/scripts/gate-event-logger-hook.ps1' | Should -Exist
    }

    It 'hook script declares Resolve-GateSessionKey' {
        $hookPath = Join-Path $script:RepoRoot 'skills/solution-authoring/scripts/gate-event-logger-hook.ps1'
        $content = Get-Content $hookPath -Raw
        $content | Should -Match 'function Resolve-GateSessionKey'
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

Describe 'hooks.json PostToolUse matcher contract' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
    }

    It 'hooks.json exists' {
        Join-Path $script:RepoRoot 'hooks.json' | Should -Exist
    }

    It 'hooks.json has AskUserQuestion matcher' {
        $hooksPath = Join-Path $script:RepoRoot 'hooks.json'
        $hooksContent = Get-Content $hooksPath -Raw | ConvertFrom-Json
        $postToolUseEntries = $hooksContent.hooks.PostToolUse
        $postToolUseEntries | Should -Not -BeNullOrEmpty
        $hasAskUserQuestion = $postToolUseEntries | Where-Object { $_.matcher -match 'AskUserQuestion' }
        $hasAskUserQuestion | Should -Not -BeNullOrEmpty
    }
}

Describe 'hooks/hooks.json PostToolUse matcher contract' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
    }

    It 'hooks/hooks.json exists' {
        Join-Path $script:RepoRoot 'hooks/hooks.json' | Should -Exist
    }

    It 'hooks/hooks.json has AskUserQuestion matcher' {
        $hooksPath = Join-Path $script:RepoRoot 'hooks/hooks.json'
        $hooksContent = Get-Content $hooksPath -Raw | ConvertFrom-Json
        $postToolUseEntries = $hooksContent.hooks.PostToolUse
        $postToolUseEntries | Should -Not -BeNullOrEmpty
        $hasAskUserQuestion = $postToolUseEntries | Where-Object { $_.matcher -match 'AskUserQuestion' }
        $hasAskUserQuestion | Should -Not -BeNullOrEmpty
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
