#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
.SYNOPSIS
    Contract tests for issue #791 CE Gate evidence-labeling browser grants and
    the uppercase-Chrome spelling regression guard.

.DESCRIPTION
    Locks:
      - Byte-exact browser MCP grant literals (`mcp__Claude_Preview__*` and
        `mcp__claude-in-chrome__*`) on the three CE-Gate-capable Claude shells:
        agents/experience-owner.md, agents/ui-iterator.md, agents/code-critic.md.
      - A repo-wide guard that the retired uppercase-Chrome spelling
        (`mcp__Claude_in_Chrome__`) does not appear anywhere in the repo except
        this test file (which must reference the literal to assert its absence).
      - A case-insensitive guard that no `mcp__claude.?in.?chrome__` tool-literal
        variant (e.g. a Title-case-hyphen regression like
        `mcp__Claude-in-Chrome__`) appears anywhere in the repo except the exact
        lowercase literal `mcp__claude-in-chrome__` and except this test file
        itself. The `mcp__` prefix and `__` suffix requirement scopes this guard
        to tool literals only, so it does not flag bare prose/display-text
        mentions of the feature name — including the byte-locked CE6
        announcement literal ("Claude-in-Chrome MCP") pinned across
        agents/ui-iterator.md, commands/polish.md,
        Documents/Design/claude-browser-tools.md, and the here-string fixture
        in specialist-shell-parity.Tests.ps1 — which must never be edited.

    Precedent for scoped self-match handling: see the anchored ^## BDD Framework
    detection-discriminator technique in bdd-scenario-contract.Tests.ps1 (issue
    #733) — this file uses an analogous self-exclusion technique (excluding its
    own file path from the repo-wide scan) rather than a line-start anchor,
    since the risk here is a file matching its own assertion-literal, not a
    heading substring false-positive.

    These tests are expected RED at authoring time (issue #791 step 1): the
    grants do not yet exist on the three shells, and the uppercase-Chrome
    spelling is still present at ~21 known locations pending the step-2 sweep.
#>

BeforeDiscovery {
    $script:CeEvidenceGrantRepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
    $script:CeEvidenceGrantTestCases = @(
        'agents/experience-owner.md',
        'agents/ui-iterator.md',
        'agents/code-critic.md'
    ) | ForEach-Object {
        @{
            RelativePath = $_
            FullPath     = (Join-Path $script:CeEvidenceGrantRepoRoot $_)
        }
    }
}

Describe 'CE Gate evidence-labeling browser grant pin (issue #791)' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:GrantFiles = @(
            'agents/experience-owner.md',
            'agents/ui-iterator.md',
            'agents/code-critic.md'
        )
        $script:SelfPath = (Resolve-Path $PSCommandPath).Path
    }

    Context 'Byte-exact grant literals on the three CE-Gate-capable shells' {

        It '<RelativePath> tools: line contains the byte-exact mcp__Claude_Preview__* grant literal' -TestCases $script:CeEvidenceGrantTestCases {
            param($RelativePath, $FullPath)
            $toolsLine = (Get-Content -Path $FullPath | Where-Object { $_ -match '^tools:' } | Select-Object -First 1)
            $toolsLine | Should -Not -BeNullOrEmpty -Because "$RelativePath must have a tools: line"
            $toolsLine | Should -Match ([regex]::Escape('mcp__Claude_Preview__*')) -Because "issue #791 AC1 requires $RelativePath's tools: line to carry the byte-exact mcp__Claude_Preview__* grant literal"
        }

        It '<RelativePath> tools: line contains the byte-exact mcp__claude-in-chrome__* grant literal (lowercase-hyphen spelling)' -TestCases $script:CeEvidenceGrantTestCases {
            param($RelativePath, $FullPath)
            $toolsLine = (Get-Content -Path $FullPath | Where-Object { $_ -match '^tools:' } | Select-Object -First 1)
            $toolsLine | Should -Not -BeNullOrEmpty -Because "$RelativePath must have a tools: line"
            $toolsLine | Should -Match ([regex]::Escape('mcp__claude-in-chrome__*')) -Because "issue #791 AC1 requires $RelativePath's tools: line to carry the byte-exact mcp__claude-in-chrome__* grant literal (lowercase-hyphen spelling, not the retired mcp__Claude_in_Chrome__ uppercase spelling)"
        }
    }

    Context 'Repo-wide uppercase-Chrome spelling guard' {

        BeforeAll {
            # Scope: every file in the repo except this test file itself (which must
            # reference the literal below to assert its absence, so it would
            # otherwise self-match). .git is excluded as non-source-controlled content.
            $script:AllRepoFiles = Get-ChildItem -Path $script:RepoRoot -Recurse -File |
                Where-Object { $_.FullName -notmatch '[/\\]\.git[/\\]' } |
                Where-Object { $_.FullName -ne $script:SelfPath }
        }

        It 'the retired uppercase-Chrome literal mcp__Claude_in_Chrome__ does not appear anywhere in the repo except this test file' {
            $needle = 'mcp__Claude_in_Chrome__'
            $violations = [System.Collections.Generic.List[string]]::new()
            foreach ($file in $script:AllRepoFiles) {
                $content = Get-Content -Path $file.FullName -Raw -ErrorAction SilentlyContinue
                if ($null -eq $content) { continue }
                if ($content.Contains($needle)) {
                    $violations.Add((Resolve-Path -Path $file.FullName -Relative -RelativeBasePath $script:RepoRoot))
                }
            }
            $violations | Should -HaveCount 0 -Because "issue #791 requires the retired uppercase-Chrome spelling mcp__Claude_in_Chrome__ to be corrected to mcp__claude-in-chrome__ everywhere in the repo (step 2 sweep); this pin fails RED until that sweep lands. Locations found: $($violations -join ', ')"
        }
    }

    Context 'Case-insensitive mcp__claude.?in.?chrome__ tool-literal variant guard (catches Title-case-hyphen regressions)' {

        BeforeAll {
            $script:AllRepoFiles = Get-ChildItem -Path $script:RepoRoot -Recurse -File |
                Where-Object { $_.FullName -notmatch '[/\\]\.git[/\\]' } |
                Where-Object { $_.FullName -ne $script:SelfPath }
            $script:VariantPattern = '(?i)mcp__claude.?in.?chrome__'
            $script:AllowedLiteral = 'mcp__claude-in-chrome__'
        }

        It 'no mcp__claude.?in.?chrome__ tool-literal variant appears anywhere in the repo except the exact lowercase mcp__claude-in-chrome__ literal' {
            $violations = [System.Collections.Generic.List[string]]::new()
            foreach ($file in $script:AllRepoFiles) {
                $lines = Get-Content -Path $file.FullName -ErrorAction SilentlyContinue
                if ($null -eq $lines) { continue }
                for ($i = 0; $i -lt $lines.Count; $i++) {
                    $line = $lines[$i]
                    if ($line -notmatch $script:VariantPattern) { continue }
                    # Strip every occurrence of the one allowed exact literal, then re-test:
                    # any remaining match on this line is a disallowed variant (e.g. Title-case-hyphen).
                    $stripped = $line -replace [regex]::Escape($script:AllowedLiteral), ''
                    if ($stripped -match $script:VariantPattern) {
                        $relativePath = Resolve-Path -Path $file.FullName -Relative -RelativeBasePath $script:RepoRoot
                        $violations.Add("$($relativePath):$($i + 1)")
                    }
                }
            }
            $violations | Should -HaveCount 0 -Because "issue #791 requires no mcp__claude.?in.?chrome__ tool-literal spelling variant (case-insensitive) other than the exact lowercase-hyphen mcp__claude-in-chrome__ literal — this catches regressions a simple uppercase-underscore grep would miss, such as mcp__Claude-in-Chrome__, while excluding bare prose/display-text mentions of the feature name (e.g. the byte-locked CE6 announcement literal) that carry no mcp__ tool prefix. Locations found: $($violations -join ', ')"
        }
    }
}
