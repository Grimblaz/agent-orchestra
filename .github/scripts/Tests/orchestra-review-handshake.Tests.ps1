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
        $script:ClaudeDispatcherPath = Join-Path $script:RepoRoot 'skills\adversarial-review\platforms\claude.md'
        $script:ClaudeDispatcherContent = Get-Content -Path $script:ClaudeDispatcherPath -Raw -ErrorAction Stop
        $script:RequiredHandshakeCommands = @(
            [pscustomobject]@{ Name = 'orchestra-review'; Path = Join-Path $script:CommandsDirectory 'orchestra-review.md' },
            [pscustomobject]@{ Name = 'orchestra-review-lite'; Path = Join-Path $script:CommandsDirectory 'orchestra-review-lite.md' },
            [pscustomobject]@{ Name = 'orchestra-review-prosecute'; Path = Join-Path $script:CommandsDirectory 'orchestra-review-prosecute.md' },
            [pscustomobject]@{ Name = 'orchestra-review-defend'; Path = Join-Path $script:CommandsDirectory 'orchestra-review-defend.md' }
        )
        $script:JudgeCommandPath = Join-Path $script:CommandsDirectory 'orchestra-review-judge.md'
        $script:CanonicalCapturePattern = '(?s)git rev-parse HEAD.*?git rev-parse --abbrev-ref HEAD.*?pwd.*?git status --porcelain \| tr -d ''\\r'' \| \(sha256sum 2>/dev/null \|\| shasum -a 256\) \| cut -c1-12'
        $script:CompositeReviewCommands = @(
            [pscustomobject]@{ Name = 'orchestra-review'; Path = Join-Path $script:CommandsDirectory 'orchestra-review.md' },
            [pscustomobject]@{ Name = 'orchestra-review-lite'; Path = Join-Path $script:CommandsDirectory 'orchestra-review-lite.md' }
        )

        $script:GetEffectiveContract = {
            param([string]$CommandContent)

            return ($CommandContent + "`n" + $script:ClaudeDispatcherContent)
        }
    }

    It 'requires the four code-critic commands to document handshake construction with the canonical live git capture order' {
        foreach ($command in $script:RequiredHandshakeCommands) {
            $commandContent = Get-Content -Path $command.Path -Raw
            $content = & $script:GetEffectiveContract -CommandContent $commandContent

            $commandContent | Should -Match 'skills/adversarial-review/platforms/claude\.md' -Because "$($command.Name) must delegate handshake construction to the shared Claude dispatcher checklist"
            $content | Should -Match 'Handshake requirement.*Required for every Code-Critic|Parent-side Environment Handshake Construction' -Because "$($command.Name) must make handshake construction mandatory through the shared dispatcher"
            $content | Should -Match $script:CanonicalCapturePattern -Because "$($command.Name) must capture HEAD, branch, pwd, then dirty fingerprint in canonical order"
            $content | Should -Match 'workspace_mode: shared' -Because "$($command.Name) must carry the shared-worktree handshake mode"
            $content | Should -Match 'handshake_issued_at' -Because "$($command.Name) must mention the issued-at field required by the schema"
            $content | Should -Match 'Preserve canonical field order exactly' -Because "$($command.Name) must forbid schema drift"
            $content | Should -Match 'skip handshake construction for that dispatch' -Because "$($command.Name) must document the non-zero-exit fallback"
        }
    }

    It 'requires the four code-critic commands to prepend the handshake block to Agent prompts' {
        foreach ($command in $script:RequiredHandshakeCommands) {
            $content = & $script:GetEffectiveContract -CommandContent (Get-Content -Path $command.Path -Raw)

            $content | Should -Match 'Prepend the constructed block as the first content of the current Code-Critic `Agent` prompt' -Because "$($command.Name) must instruct callers to prepend the handshake block to the Agent prompt"
            $content | Should -Match 'subagent_type: code-critic' -Because "$($command.Name) must route the handshake-bearing dispatch to code-critic"
        }
    }

    It 'requires composite review commands to freshly recapture handshakes before each Code-Critic dispatch' {
        foreach ($command in $script:CompositeReviewCommands) {
            $content = & $script:GetEffectiveContract -CommandContent (Get-Content -Path $command.Path -Raw)

            $content | Should -Match '(?is)Immediately before each Code-Critic dispatch or retry, capture.{0,260}git rev-parse HEAD.{0,180}git rev-parse --abbrev-ref HEAD.{0,120}pwd.{0,220}git status --porcelain' -Because "$($command.Name) must require live handshake recapture immediately before each Code-Critic prosecution, defense, or retry dispatch"
            $content | Should -Match '(?is)(?:fresh|newly recaptured|live|per-dispatch).{0,120}(?:handshake block|handshake|capture)' -Because "$($command.Name) must name the dispatched Code-Critic handshake as fresh rather than reusable"
        }
    }

    It 'requires redundant full-review retries to use a newly recaptured handshake' {
        $content = & $script:GetEffectiveContract -CommandContent (Get-Content -Path (Join-Path $script:CommandsDirectory 'orchestra-review.md') -Raw)

        $content | Should -Match '(?is)retry.{0,240}(?:newly recaptured|fresh|recapture|reconstruct|capture).{0,180}(?:handshake block|handshake|capture)' -Because '/orchestra:review must retry redundant prosecution with a newly recaptured handshake, not the stale first-attempt block'
    }

    It 'rejects stale handshake reuse wording in composite review commands' {
        foreach ($command in $script:CompositeReviewCommands) {
            $content = Get-Content -Path $command.Path -Raw

            $content | Should -Not -Match '(?is)\bsame\s+(?:substantive\s+)?prompt\s+and\s+(?:the\s+)?(?:same\s+)?handshake\s+block' -Because "$($command.Name) must not describe retrying with the same prompt and handshake block"
            $content | Should -Not -Match '(?is)prepend\s+the\s+handshake\s+block\s+again\s+when\s+constructed' -Because "$($command.Name) must not imply that later Code-Critic dispatches reuse an earlier handshake block"
        }
    }

    It 'keeps composite judge dispatches out of required Step 0 handshake scope' {
        foreach ($command in $script:CompositeReviewCommands) {
            $content = Get-Content -Path $command.Path -Raw

            $content | Should -Not -Match '(?is)(?:Handshake preamble|Step 0).{0,300}subagent_type:\s*code-review-response|subagent_type:\s*code-review-response.{0,300}(?:Handshake preamble|Step 0)' -Because "$($command.Name) must not require Code-Review-Response judge dispatches to perform Step 0 handshake verification"
        }
    }

    It 'documents judge handshake as optional contextual input rather than a required verifier gate' {
        $content = & $script:GetEffectiveContract -CommandContent (Get-Content -Path $script:JudgeCommandPath -Raw)

        $content | Should -Match 'judge receives existing prosecution and defense ledgers' -Because 'the judge command must keep judge-only dispatch contextual'
        $content | Should -Match 'metadata only' -Because 'the judge command must not require Code-Critic handshake verification'
        $content | Should -Match 'Do not prepend a Step 0 verifier handshake block to the judge prompt unless Code-Review-Response gains explicit Step 0 verification in a separate issue' -Because 'the judge command must explain why the handshake is contextual only'
        $content | Should -Not -Match '\*\*Handshake preamble\*\* \(required' -Because 'the judge command must not present handshake construction as mandatory'
    }
}
