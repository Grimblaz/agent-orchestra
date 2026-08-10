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
    presentation mechanism has no reliable trigger once the surfaces Claude loads
    specify no mechanism for surfacing a decision, and its output had not been
    written since 2026-07-18. The four hook-specific assertions in this suite were
    re-pointed rather than deleted, and became six: three assert the retirement held,
    and three follow `Resolve-GateSessionKey` to its new home by invoking it (primary
    branch, fallback rung, degenerate-input guard). The eight non-hook assertions
    (schema, #556 regression guard, reconciler library) are unchanged and must keep
    passing. Fourteen assertions, plus one more (#1052 GH-2, a detached-checkout
    guard against `b-HEAD`) added during PR #1052's own GitHub-review-intake pass.
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

    It 'Resolve-GateSessionKey never returns b-HEAD on a detached checkout (#1052 GH-2)' {
        # A real detached checkout, not a mock: `git rev-parse --abbrev-ref HEAD` behaves
        # differently on a detached HEAD than a missing/failed lookup (exit 0, literal "HEAD"),
        # which a mocked LASTEXITCODE could not reproduce.
        $scratch = Join-Path ([System.IO.Path]::GetTempPath()) ("gsk-detached-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $scratch -Force | Out-Null
        try {
            Push-Location $scratch
            git init --quiet 2>$null
            git config user.email 'test@example.com' 2>$null
            git config user.name 'Test' 2>$null
            'a' | Out-File -FilePath 'a.txt' -Encoding utf8
            git add a.txt 2>$null
            git commit --quiet -m 'first' 2>$null
            $sha = (git rev-parse --short HEAD 2>$null).Trim()
            git checkout --quiet --detach HEAD 2>$null

            $branchProbe = (git rev-parse --abbrev-ref HEAD 2>$null)
            $branchProbe | Should -Be 'HEAD' -Because 'the detached-HEAD reproduction depends on this literal, non-error return'

            $key = Resolve-GateSessionKey
            $key | Should -Not -Be 'b-HEAD' -Because 'a detached checkout must not collide on a shared branch-shaped key'
            $key | Should -Be "sha-$sha" -Because 'a detached checkout must fall through to the sha rung'
        }
        finally {
            Pop-Location
            Remove-Item -Path $scratch -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'Resolve-GateSessionKey never returns the degenerate bare key (#1003 M26)' {
        # An id made only of characters the sanitizer strips must fall through to the next
        # rung, not collapse to "s-" and merge every such session into one log file.
        foreach ($degenerate in @('---', '///', '   ', '@@@')) {
            $key = Resolve-GateSessionKey -SessionId $degenerate
            $key | Should -Not -Be 's-' -Because "'$degenerate' must not produce the bare key"
            $key | Should -Match '^(b-|sha-|session$)' `
                -Because "'$degenerate' must drop to the branch-slug rung"
        }
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
