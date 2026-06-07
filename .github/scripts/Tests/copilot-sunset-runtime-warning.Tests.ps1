#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
.SYNOPSIS
    Contract: the Copilot-only root hooks.json carries the sunset warning;
    the Claude hooks/hooks.json does NOT.
.DESCRIPTION
    AC4 / Design D-B / F1: the runtime sunset warning must be injected into
    root hooks.json (Copilot-only file) and must never appear in
    hooks/hooks.json (Claude file). Discriminator is structural — root hooks.json
    is loaded only by Copilot/VS Code; the Claude plugin uses hooks/hooks.json.

    The once-state mechanism uses '~/.agent-orchestra/copilot-sunset-ack' so
    the warning fires once per machine and does not re-nag the maintainer (F15).
#>

Describe 'Copilot sunset runtime warning contract (#651)' {
    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:CopilotHooksPath = Join-Path $script:RepoRoot 'hooks.json'
        $script:ClaudeHooksPath  = Join-Path $script:RepoRoot 'hooks' 'hooks.json'

        function script:Get-SessionStartCommand {
            param([string]$HooksPath)
            $config = Get-Content -Raw -Path $HooksPath | ConvertFrom-Json
            $sessionEntries = $config.hooks.SessionStart
            if (-not $sessionEntries) { return $null }
            return $sessionEntries[0].hooks[0].command
        }
    }

    It 'root hooks.json Copilot SessionStart contains the sunset-warning ack token' {
        $command = script:Get-SessionStartCommand -HooksPath $script:CopilotHooksPath
        $command | Should -Not -BeNullOrEmpty
        $command | Should -Match 'copilot-sunset-ack' `
            -Because 'root hooks.json must carry the once-state ack file path for the Copilot sunset warning (AC4)'
    }

    It 'root hooks.json Copilot SessionStart contains the retire-after-2026-08-31 message' {
        $command = script:Get-SessionStartCommand -HooksPath $script:CopilotHooksPath
        $command | Should -Not -BeNullOrEmpty
        $command | Should -Match '2026-08-31' `
            -Because 'the sunset warning message must include the retirement date (AC4 / D-B)'
    }

    It 'hooks/hooks.json Claude SessionStart does NOT contain the sunset-warning ack token' {
        $command = script:Get-SessionStartCommand -HooksPath $script:ClaudeHooksPath
        $command | Should -Not -BeNullOrEmpty
        $command | Should -Not -Match 'copilot-sunset-ack' `
            -Because 'hooks/hooks.json is the Claude-only file — the Copilot sunset warning must never fire for Claude users (AC4 / F1)'
    }

    It 'root hooks.json sunset warning fires BEFORE the session-cleanup-detector call' {
        $command = script:Get-SessionStartCommand -HooksPath $script:CopilotHooksPath
        $command | Should -Not -BeNullOrEmpty -Because 'prerequisite: SessionStart command must be readable to check ordering'
        $ackIdx      = $command.IndexOf('copilot-sunset-ack')
        $detectorIdx = $command.IndexOf('session-cleanup-detector.ps1')
        $ackIdx      | Should -BeGreaterOrEqual 0 -Because 'ack token must be present'
        $detectorIdx | Should -BeGreaterOrEqual 0 -Because 'detector path must still be present'
        $ackIdx      | Should -BeLessThan $detectorIdx `
            -Because 'the sunset warning must be injected BEFORE the session-cleanup-detector call (Design D-B)'
    }
}
