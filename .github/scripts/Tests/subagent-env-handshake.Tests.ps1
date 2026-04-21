# scope: claude-only
#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    Contract tests for the subagent-env-handshake v1 skill.

.DESCRIPTION
    Seven scenarios:
      (a) construction      — New-SubagentDispatchPrompt produces the canonical schema block
      (b) fingerprint       — Get-DirtyTreeFingerprint is deterministic and input-sensitive
      (c) verifier match    — identical handshake + observed → outcome 'match'
      (d) verifier mismatch — divergent HEAD → outcome 'mismatch' with correct diverged_fields + ND-2 heading
      (e) verifier error    — missing handshake OR git-failed → outcome 'missing-handshake'/'error' with environment-unverified tag
      (f) schema parity     — the six field names in SKILL.md (between the schema sentinels) match the helper's output and the verifier stub's required-field list
      (g) stub-vs-prose     — the verifier stub's decision-tree block matches the decision-tree anchor in agents/issue-planner.md Step 0

    Scope: claude-only.
#>

Describe 'subagent-env-handshake v1 contract' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:HelperPath = Join-Path $script:RepoRoot 'skills/subagent-env-handshake/scripts/New-SubagentDispatchPrompt.ps1'
        $script:VerifierStubPath = Join-Path $PSScriptRoot 'fixtures/subagent-env-handshake-verifier.ps1'
        $script:SkillMdPath = Join-Path $script:RepoRoot 'skills/subagent-env-handshake/SKILL.md'
        $script:IssuePlannerShellPath = Join-Path $script:RepoRoot 'agents/issue-planner.md'

        . $script:HelperPath
        . $script:VerifierStubPath

        $script:CanonicalFields = @(
            'parent_head',
            'parent_branch',
            'parent_cwd',
            'parent_dirty_fingerprint',
            'workspace_mode',
            'handshake_issued_at'
        )

        $script:SampleBlock = New-SubagentDispatchPrompt `
            -HeadSha '6bf7aaa0be4647c8b582442aeb192290dcf695cf' `
            -Branch 'feature/issue-383-subagent-env-consistency' `
            -Cwd '/c/Users/Micah/Code 2/copilot-orchestra' `
            -DirtyFingerprint 'abc123456789' `
            -WorkspaceMode 'shared' `
            -IssuedAt '2026-04-20T22:19:47.0000000Z'

        $script:SampleObserved = @{
            parent_head              = '6bf7aaa0be4647c8b582442aeb192290dcf695cf'
            parent_branch            = 'feature/issue-383-subagent-env-consistency'
            parent_cwd               = '/c/Users/Micah/Code 2/copilot-orchestra'
            parent_dirty_fingerprint = 'abc123456789'
        }
    }

    Context 'Scenario (a) — construction' {
        It 'emits the schema block with all six canonical fields in order' {
            $lines = $script:SampleBlock -split "`n"
            $lines[0] | Should -Be '<!-- subagent-env-handshake v1 -->'
            $lines[-1] | Should -Be '<!-- /subagent-env-handshake -->'

            # Lines 1..6 are the six `key: value` pairs in canonical order.
            for ($i = 0; $i -lt $script:CanonicalFields.Count; $i++) {
                $expectedKey = $script:CanonicalFields[$i]
                $lines[$i + 1] | Should -Match ('^' + [regex]::Escape($expectedKey) + ':\s')
            }
        }

        It 'populates parent_head from the HeadSha parameter' {
            $script:SampleBlock | Should -Match 'parent_head:\s+6bf7aaa0be4647c8b582442aeb192290dcf695cf'
        }

        It 'rejects an invalid HeadSha that is not 40 hex characters' {
            { New-SubagentDispatchPrompt -HeadSha 'nothex' -Branch 'main' -Cwd '/tmp' -DirtyFingerprint 'abc123456789' } |
                Should -Throw
        }
    }

    Context 'Scenario (b) — fingerprint determinism' {
        It 'returns the same fingerprint for identical porcelain input' {
            $a = Get-DirtyTreeFingerprint -PorcelainOutput " M file1.txt`n?? file2.txt"
            $b = Get-DirtyTreeFingerprint -PorcelainOutput " M file1.txt`n?? file2.txt"
            $a | Should -Be $b
        }

        It 'returns a different fingerprint for a one-byte-different input' {
            $a = Get-DirtyTreeFingerprint -PorcelainOutput " M file1.txt"
            $b = Get-DirtyTreeFingerprint -PorcelainOutput " M File1.txt"
            $a | Should -Not -Be $b
        }

        It 'normalizes CRLF and CR to LF before hashing' {
            $lf = Get-DirtyTreeFingerprint -PorcelainOutput " M a`n M b"
            $crlf = Get-DirtyTreeFingerprint -PorcelainOutput " M a`r`n M b"
            $cr = Get-DirtyTreeFingerprint -PorcelainOutput " M a`r M b"
            $lf | Should -Be $crlf
            $lf | Should -Be $cr
        }

        It 'emits exactly 12 lowercase hex characters' {
            $fp = Get-DirtyTreeFingerprint -PorcelainOutput 'anything'
            $fp | Should -Match '^[0-9a-f]{12}$'
        }

        It 'returns a 12-char lowercase hex fingerprint for empty (clean-tree) porcelain output' {
            $fp = Get-DirtyTreeFingerprint -PorcelainOutput ''
            $fp | Should -Match '^[0-9a-f]{12}$'
            # SHA-256 of empty bytes: e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
            $fp | Should -Be 'e3b0c44298fc'
        }

        It 'returns a 12-char lowercase hex string via the live git code path' {
            if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
                Set-ItResult -Skipped -Because 'git not available in test environment'
                return
            }
            $fp = Get-DirtyTreeFingerprint
            $fp | Should -Match '^[0-9a-f]{12}$'
        }
    }

    Context 'Scenario (c) — verifier match path' {
        It 'returns outcome match when handshake fields equal observed fields' {
            $result = Invoke-SubagentEnvHandshakeVerifier `
                -PromptText $script:SampleBlock `
                -Observed $script:SampleObserved
            $result.outcome | Should -Be 'match'
        }
    }

    Context 'Scenario (d) — verifier mismatch path' {
        It 'returns outcome mismatch with diverged_fields listing only parent_head' {
            $observed = @{} + $script:SampleObserved
            $observed['parent_head'] = 'ffffffffffffffffffffffffffffffffffffffff'

            $result = Invoke-SubagentEnvHandshakeVerifier `
                -PromptText $script:SampleBlock `
                -Observed $observed

            $result.outcome | Should -Be 'mismatch'
            @($result.diverged_fields) | Should -Be @('parent_head')
        }

        It 'emits the ND-2 finding heading verbatim' {
            $observed = @{} + $script:SampleObserved
            $observed['parent_head'] = 'ffffffffffffffffffffffffffffffffffffffff'

            $result = Invoke-SubagentEnvHandshakeVerifier `
                -PromptText $script:SampleBlock `
                -Observed $observed

            $result.finding_heading | Should -Be '## Finding: environment-divergence (halting)'
        }

        It 'lists multiple diverged fields when more than one differs' {
            $observed = @{} + $script:SampleObserved
            $observed['parent_head'] = 'ffffffffffffffffffffffffffffffffffffffff'
            $observed['parent_branch'] = 'other-branch'

            $result = Invoke-SubagentEnvHandshakeVerifier `
                -PromptText $script:SampleBlock `
                -Observed $observed

            @($result.diverged_fields) | Should -Contain 'parent_head'
            @($result.diverged_fields) | Should -Contain 'parent_branch'
        }
    }

    Context 'Scenario (e) — verifier error / missing-handshake path' {
        It 'returns missing-handshake with environment-unverified tag when no block is present' {
            $result = Invoke-SubagentEnvHandshakeVerifier `
                -PromptText 'no handshake block here, just task text' `
                -Observed $script:SampleObserved
            $result.outcome | Should -Be 'missing-handshake'
            $result.tag | Should -Be 'environment-unverified'
        }

        It 'returns error with environment-unverified tag when GitFailed is signalled' {
            $result = Invoke-SubagentEnvHandshakeVerifier `
                -PromptText $script:SampleBlock `
                -Observed $script:SampleObserved `
                -GitFailed
            $result.outcome | Should -Be 'error'
            $result.tag | Should -Be 'environment-unverified'
        }

        It 'returns error with environment-unverified tag when workspace_mode is worktree (reserved in v1)' {
            $worktreeBlock = New-SubagentDispatchPrompt `
                -HeadSha '6bf7aaa0be4647c8b582442aeb192290dcf695cf' `
                -Branch 'main' `
                -Cwd '/tmp' `
                -DirtyFingerprint 'abc123456789' `
                -WorkspaceMode 'worktree'
            $result = Invoke-SubagentEnvHandshakeVerifier `
                -PromptText $worktreeBlock `
                -Observed $script:SampleObserved
            $result.outcome | Should -Be 'error'
            $result.tag | Should -Be 'environment-unverified'
        }

        It 'returns error with environment-unverified tag when Observed is null' {
            $result = Invoke-SubagentEnvHandshakeVerifier `
                -PromptText $script:SampleBlock `
                -Observed $null
            $result.outcome | Should -Be 'error'
            $result.tag | Should -Be 'environment-unverified'
        }
    }

    Context 'Scenario (f) — schema parity across SKILL.md, helper, verifier stub' {
        It 'the six field names bounded by the SKILL.md schema sentinels equal the helper-canonical field list' {
            $skillContent = Get-Content -Path $script:SkillMdPath -Raw
            $boundedPattern = '(?ms)# --- subagent-env-handshake v1 schema begin ---\s*\r?\n(?<schema>.*?)\r?\n\s*# --- subagent-env-handshake v1 schema end ---'
            $match = [regex]::Match($skillContent, $boundedPattern)
            $match.Success | Should -BeTrue -Because 'SKILL.md must carry the schema-begin/end sentinels'

            $schemaBody = $match.Groups['schema'].Value
            $skillFields = @(
                [regex]::Matches($schemaBody, '(?m)^(?<key>[a-z_]+):') |
                    ForEach-Object { $_.Groups['key'].Value }
            )

            $skillFields.Count | Should -Be $script:CanonicalFields.Count -Because 'SKILL.md schema must list exactly the canonical six fields'
            for ($i = 0; $i -lt $script:CanonicalFields.Count; $i++) {
                $skillFields[$i] | Should -Be $script:CanonicalFields[$i] -Because "SKILL.md schema field #$($i + 1) must match canonical order"
            }
        }

        It 'the verifier stub Read function requires exactly the canonical six fields' {
            $stubContent = Get-Content -Path $script:VerifierStubPath -Raw
            $requiredPattern = "requiredFields = @\('parent_head', 'parent_branch', 'parent_cwd', 'parent_dirty_fingerprint', 'workspace_mode', 'handshake_issued_at'\)"
            $stubContent | Should -Match $requiredPattern -Because 'the verifier stub must require the same six fields in the canonical order'
        }
    }

    Context 'Scenario (g) — stub-vs-prose decision-tree parity' {
        It 'the four decision-tree outcomes appear in the same order in stub and Claude shell' {
            $stubContent = Get-Content -Path $script:VerifierStubPath -Raw
            $shellContent = Get-Content -Path $script:IssuePlannerShellPath -Raw

            $outcomePattern = '(?m)^\s*(?:#\s+)?(?<num>[1-4])\.\s+(?<outcome>match|mismatch|error|missing-handshake)\b\s*(?:-\s*)?(?:->.*)?$'

            $stubDecisionBlock = [regex]::Match(
                $stubContent,
                '(?ms)# --- subagent-env-handshake v1 decision tree ---\s*\r?\n(?<body>.*?)\r?\n# --- end subagent-env-handshake v1 decision tree ---'
            )
            $stubDecisionBlock.Success | Should -BeTrue -Because 'the verifier stub must carry a sentinel-bounded decision-tree block'

            $shellDecisionBlock = [regex]::Match(
                $shellContent,
                '(?ms)<!-- subagent-env-handshake v1 decision tree -->\s*\r?\n(?<body>.*?)\r?\n<!-- /subagent-env-handshake v1 decision tree -->'
            )
            $shellDecisionBlock.Success | Should -BeTrue -Because 'agents/issue-planner.md Step 0 must carry a sentinel-bounded decision-tree anchor block'

            $stubOutcomes = @(
                [regex]::Matches($stubDecisionBlock.Groups['body'].Value, $outcomePattern) |
                    ForEach-Object { $_.Groups['outcome'].Value }
            )
            $shellOutcomes = @(
                [regex]::Matches($shellDecisionBlock.Groups['body'].Value, $outcomePattern) |
                    ForEach-Object { $_.Groups['outcome'].Value }
            )

            $stubOutcomes.Count | Should -Be 4 -Because 'stub decision tree must enumerate exactly four outcomes'
            $shellOutcomes.Count | Should -Be 4 -Because 'shell decision tree anchor must enumerate exactly four outcomes'

            for ($i = 0; $i -lt 4; $i++) {
                $shellOutcomes[$i] | Should -Be $stubOutcomes[$i] -Because "outcome #$($i + 1) must match lockstep between stub and shell"
            }

            $expectedOrder = @('match', 'mismatch', 'error', 'missing-handshake')
            for ($i = 0; $i -lt 4; $i++) {
                $stubOutcomes[$i] | Should -Be $expectedOrder[$i] -Because "outcome #$($i + 1) must be canonical v1 ordering"
            }
        }
    }
}
