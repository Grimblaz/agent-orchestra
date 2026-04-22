#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    Contract tests for Claude review command handshake documentation.

.DESCRIPTION
    Locks issue #379 Step 7 handshake expectations:
      - four commands require handshake construction for code-critic dispatches
      - command prose names the live git capture order and canonical schema notes
      - judge documents the handshake as optional/contextual only
#>

Describe 'orchestra-review handshake contract' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:CommandsDirectory = Join-Path $script:RepoRoot 'commands'
        $script:RequiredHandshakeCommands = @(
            [pscustomobject]@{ Name = 'orchestra-review'; Path = Join-Path $script:CommandsDirectory 'orchestra-review.md' },
            [pscustomobject]@{ Name = 'orchestra-review-lite'; Path = Join-Path $script:CommandsDirectory 'orchestra-review-lite.md' },
            [pscustomobject]@{ Name = 'orchestra-review-prosecute'; Path = Join-Path $script:CommandsDirectory 'orchestra-review-prosecute.md' },
            [pscustomobject]@{ Name = 'orchestra-review-defend'; Path = Join-Path $script:CommandsDirectory 'orchestra-review-defend.md' }
        )
        $script:JudgeCommandPath = Join-Path $script:CommandsDirectory 'orchestra-review-judge.md'
        $script:CanonicalCapturePattern = '(?s)git rev-parse HEAD.*?git rev-parse --abbrev-ref HEAD.*?pwd.*?git status --porcelain \| tr -d ''\\r'' \| \(sha256sum 2>/dev/null \|\| shasum -a 256\) \| cut -c1-12'
    }

    It 'requires the four code-critic commands to document handshake construction with the canonical live git capture order' {
        foreach ($command in $script:RequiredHandshakeCommands) {
            $content = Get-Content -Path $command.Path -Raw

            $content | Should -Match '\*\*Handshake preamble\*\* \(required' -Because "$($command.Name) must make handshake construction mandatory"
            $content | Should -Match $script:CanonicalCapturePattern -Because "$($command.Name) must capture HEAD, branch, pwd, then dirty fingerprint in canonical order"
            $content | Should -Match 'workspace_mode: shared' -Because "$($command.Name) must carry the shared-worktree handshake mode"
            $content | Should -Match 'handshake_issued_at' -Because "$($command.Name) must mention the issued-at field required by the schema"
            $content | Should -Match 'field-for-field and in canonical order' -Because "$($command.Name) must forbid schema drift"
            $content | Should -Match 'skip handshake construction entirely' -Because "$($command.Name) must document the non-zero-exit fallback"
        }
    }

    It 'requires the four code-critic commands to prepend the handshake block to Agent prompts' {
        foreach ($command in $script:RequiredHandshakeCommands) {
            $content = Get-Content -Path $command.Path -Raw

            $content | Should -Match 'Prepend the handshake block as the \*\*first content\*\* of the `prompt` parameter' -Because "$($command.Name) must instruct callers to prepend the handshake block to the Agent prompt"
            $content | Should -Match 'subagent_type: code-critic' -Because "$($command.Name) must route the handshake-bearing dispatch to code-critic"
        }
    }

    It 'documents judge handshake as optional contextual input rather than a required verifier gate' {
        $content = Get-Content -Path $script:JudgeCommandPath -Raw

        $content | Should -Match '\*\*Optional handshake context\*\*' -Because 'the judge command must explicitly document the handshake as optional'
        $content | Should -Match 'you may construct the same `<!-- subagent-env-handshake v1 -->` block described in `commands/plan.md`' -Because 'the judge command must point power users at the same handshake block shape'
        $content | Should -Match 'This is optional for `/orchestra:review-judge`' -Because 'the judge command must not require handshake construction'
        $content | Should -Match 'does not run a Step 0 verifier' -Because 'the judge command must explain why the handshake is contextual only'
        $content | Should -Not -Match '\*\*Handshake preamble\*\* \(required' -Because 'the judge command must not present handshake construction as mandatory'
    }
}
