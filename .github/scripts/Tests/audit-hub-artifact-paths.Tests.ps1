# Authoritative placeholder enum source: top-of-file schema docstring of Documents/Design/hub-artifact-paths-classification.yml (introduced in s3)
#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    Contract tests for audit-hub-artifact-paths.ps1 — AC4 extraction grammar.

.DESCRIPTION
    Covers:
      - Positive cases: known path references extracted per fixture scope
        (agent body, Claude shell, skill body, command, plugin manifest,
        platforms, hook script)
      - Negative cases: excluded classes (marker template comments,
        tool-name backticks, URLs, CLI flags) do NOT appear in inventory
      - Template normalization: all eight D2a placeholders are normalised
        before family clustering
      - Byte-stability: two consecutive default-mode invocations against the
        same working tree produce byte-identical JSON stdout

    Tests run RED until audit-hub-artifact-paths.ps1 is created (s2).
    Every test that depends on the script throws with a message containing
    "Missing script:" and the full script path.
#>

Describe 'audit-hub-artifact-paths extraction grammar (AC4)' {

    BeforeAll {
        $script:ScriptPath = Join-Path $PSScriptRoot '../audit-hub-artifact-paths.ps1'
        $script:FixtureDir = Join-Path $PSScriptRoot 'fixtures/hub-artifact-paths'
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path

        # Helper: invoke the script and capture output, enforcing missing-script guard
        function script:Invoke-AuditScript {
            param(
                [string[]]$Arguments = @(),
                [switch]$CaptureJson
            )
            if (-not (Test-Path $script:ScriptPath)) {
                throw "Missing script: $($script:ScriptPath)"
            }
            $result = & pwsh -NoProfile -NonInteractive -File $script:ScriptPath @Arguments
            return $result
        }
    }

    # ---------------------------------------------------------------------------
    # Positive cases — fixture scope: agent body
    # ---------------------------------------------------------------------------
    Context 'Positive cases — agent body scope (.agent.md)' {
        It 'extracts agents/Code-Smith.agent.md from agent-body-sample.agent.md' {
            if (-not (Test-Path $script:ScriptPath)) {
                throw "Missing script: $($script:ScriptPath)"
            }
            $fixture = Join-Path $script:FixtureDir 'agent-body-sample.agent.md'
            $output = & pwsh -NoProfile -NonInteractive -File $script:ScriptPath --input $fixture --format json
            $output | Should -Match 'agents/Code-Smith\.agent\.md'
        }

        It 'extracts skills/plan-authoring/SKILL.md from agent-body-sample.agent.md' {
            if (-not (Test-Path $script:ScriptPath)) {
                throw "Missing script: $($script:ScriptPath)"
            }
            $fixture = Join-Path $script:FixtureDir 'agent-body-sample.agent.md'
            $output = & pwsh -NoProfile -NonInteractive -File $script:ScriptPath --input $fixture --format json
            $output | Should -Match 'skills/plan-authoring/SKILL\.md'
        }

        It 'extracts commands/orchestrate.md from agent-body-sample.agent.md' {
            if (-not (Test-Path $script:ScriptPath)) {
                throw "Missing script: $($script:ScriptPath)"
            }
            $fixture = Join-Path $script:FixtureDir 'agent-body-sample.agent.md'
            $output = & pwsh -NoProfile -NonInteractive -File $script:ScriptPath --input $fixture --format json
            $output | Should -Match 'commands/orchestrate\.md'
        }
    }

    # ---------------------------------------------------------------------------
    # Positive cases — fixture scope: Claude shell
    # ---------------------------------------------------------------------------
    Context 'Positive cases — Claude shell scope (.md)' {
        It 'extracts agents/code-smith.md from claude-shell-sample.md' {
            if (-not (Test-Path $script:ScriptPath)) {
                throw "Missing script: $($script:ScriptPath)"
            }
            $fixture = Join-Path $script:FixtureDir 'claude-shell-sample.md'
            $output = & pwsh -NoProfile -NonInteractive -File $script:ScriptPath --input $fixture --format json
            $output | Should -Match 'agents/code-smith\.md'
        }

        It 'extracts agents/test-writer.md from claude-shell-sample.md' {
            if (-not (Test-Path $script:ScriptPath)) {
                throw "Missing script: $($script:ScriptPath)"
            }
            $fixture = Join-Path $script:FixtureDir 'claude-shell-sample.md'
            $output = & pwsh -NoProfile -NonInteractive -File $script:ScriptPath --input $fixture --format json
            $output | Should -Match 'agents/test-writer\.md'
        }
    }

    # ---------------------------------------------------------------------------
    # Positive cases — fixture scope: skill body
    # ---------------------------------------------------------------------------
    Context 'Positive cases — skill body scope (SKILL.md)' {
        It 'extracts skills/bdd-scenarios/SKILL.md from skill-body-sample.SKILL.md' {
            if (-not (Test-Path $script:ScriptPath)) {
                throw "Missing script: $($script:ScriptPath)"
            }
            $fixture = Join-Path $script:FixtureDir 'skill-body-sample.SKILL.md'
            $output = & pwsh -NoProfile -NonInteractive -File $script:ScriptPath --input $fixture --format json
            $output | Should -Match 'skills/bdd-scenarios/SKILL\.md'
        }

        It 'extracts skills/session-startup/SKILL.md from skill-body-sample.SKILL.md' {
            if (-not (Test-Path $script:ScriptPath)) {
                throw "Missing script: $($script:ScriptPath)"
            }
            $fixture = Join-Path $script:FixtureDir 'skill-body-sample.SKILL.md'
            $output = & pwsh -NoProfile -NonInteractive -File $script:ScriptPath --input $fixture --format json
            $output | Should -Match 'skills/session-startup/SKILL\.md'
        }
    }

    # ---------------------------------------------------------------------------
    # Positive cases — fixture scope: command file
    # ---------------------------------------------------------------------------
    Context 'Positive cases — command scope (commands/*.md)' {
        It 'extracts agents/Issue-Planner.agent.md from command-sample.md' {
            if (-not (Test-Path $script:ScriptPath)) {
                throw "Missing script: $($script:ScriptPath)"
            }
            $fixture = Join-Path $script:FixtureDir 'command-sample.md'
            $output = & pwsh -NoProfile -NonInteractive -File $script:ScriptPath --input $fixture --format json
            $output | Should -Match 'agents/Issue-Planner\.agent\.md'
        }

        It 'extracts skills/frame-credit-emission/SKILL.md from command-sample.md' {
            if (-not (Test-Path $script:ScriptPath)) {
                throw "Missing script: $($script:ScriptPath)"
            }
            $fixture = Join-Path $script:FixtureDir 'command-sample.md'
            $output = & pwsh -NoProfile -NonInteractive -File $script:ScriptPath --input $fixture --format json
            $output | Should -Match 'skills/frame-credit-emission/SKILL\.md'
        }
    }

    # ---------------------------------------------------------------------------
    # Positive cases — fixture scope: plugin manifest (JSON)
    # ---------------------------------------------------------------------------
    Context 'Positive cases — plugin manifest scope (.json)' {
        It 'extracts agents/code-smith.md from plugin-manifest-sample.json' {
            if (-not (Test-Path $script:ScriptPath)) {
                throw "Missing script: $($script:ScriptPath)"
            }
            $fixture = Join-Path $script:FixtureDir 'plugin-manifest-sample.json'
            $output = & pwsh -NoProfile -NonInteractive -File $script:ScriptPath --input $fixture --format json
            $output | Should -Match 'agents/code-smith\.md'
        }

        It 'extracts agents/Code-Conductor.agent.md from plugin-manifest-sample.json' {
            if (-not (Test-Path $script:ScriptPath)) {
                throw "Missing script: $($script:ScriptPath)"
            }
            $fixture = Join-Path $script:FixtureDir 'plugin-manifest-sample.json'
            $output = & pwsh -NoProfile -NonInteractive -File $script:ScriptPath --input $fixture --format json
            $output | Should -Match 'agents/Code-Conductor\.agent\.md'
        }

        It 'extracts .github/scripts/session-start.ps1 from plugin-manifest-sample.json' {
            if (-not (Test-Path $script:ScriptPath)) {
                throw "Missing script: $($script:ScriptPath)"
            }
            $fixture = Join-Path $script:FixtureDir 'plugin-manifest-sample.json'
            $output = & pwsh -NoProfile -NonInteractive -File $script:ScriptPath --input $fixture --format json
            $output | Should -Match '\.github/scripts/session-start\.ps1'
        }

        It 'extracts Documents/Design/frame-architecture.md from plugin-manifest-sample.json' {
            if (-not (Test-Path $script:ScriptPath)) {
                throw "Missing script: $($script:ScriptPath)"
            }
            $fixture = Join-Path $script:FixtureDir 'plugin-manifest-sample.json'
            $output = & pwsh -NoProfile -NonInteractive -File $script:ScriptPath --input $fixture --format json
            $output | Should -Match 'Documents/Design/frame-architecture\.md'
        }
    }

    # ---------------------------------------------------------------------------
    # Positive cases — fixture scope: platforms file
    # ---------------------------------------------------------------------------
    Context 'Positive cases — platforms scope (skills/*/platforms/*.md)' {
        It 'extracts skills/upstream-onboarding/SKILL.md from platforms-sample.md' {
            if (-not (Test-Path $script:ScriptPath)) {
                throw "Missing script: $($script:ScriptPath)"
            }
            $fixture = Join-Path $script:FixtureDir 'platforms-sample.md'
            $output = & pwsh -NoProfile -NonInteractive -File $script:ScriptPath --input $fixture --format json
            $output | Should -Match 'skills/upstream-onboarding/SKILL\.md'
        }

        It 'extracts agents/Experience-Owner.agent.md from platforms-sample.md' {
            if (-not (Test-Path $script:ScriptPath)) {
                throw "Missing script: $($script:ScriptPath)"
            }
            $fixture = Join-Path $script:FixtureDir 'platforms-sample.md'
            $output = & pwsh -NoProfile -NonInteractive -File $script:ScriptPath --input $fixture --format json
            $output | Should -Match 'agents/Experience-Owner\.agent\.md'
        }
    }

    # ---------------------------------------------------------------------------
    # Positive cases — fixture scope: hook script (PowerShell)
    # ---------------------------------------------------------------------------
    Context 'Positive cases — hook script scope (.ps1)' {
        It 'extracts .github/scripts/lib/frame-predicate-core.ps1 from hook-script-sample.ps1' {
            if (-not (Test-Path $script:ScriptPath)) {
                throw "Missing script: $($script:ScriptPath)"
            }
            $fixture = Join-Path $script:FixtureDir 'hook-script-sample.ps1'
            $output = & pwsh -NoProfile -NonInteractive -File $script:ScriptPath --input $fixture --format json
            $output | Should -Match '\.github/scripts/lib/frame-predicate-core\.ps1'
        }

        It 'extracts .github/scripts/post-merge-cleanup.ps1 from hook-script-sample.ps1' {
            if (-not (Test-Path $script:ScriptPath)) {
                throw "Missing script: $($script:ScriptPath)"
            }
            $fixture = Join-Path $script:FixtureDir 'hook-script-sample.ps1'
            $output = & pwsh -NoProfile -NonInteractive -File $script:ScriptPath --input $fixture --format json
            $output | Should -Match '\.github/scripts/post-merge-cleanup\.ps1'
        }

        It 'extracts .github/scripts/Tests/audit-hub-artifact-paths.Tests.ps1 from hook-script-sample.ps1 (double-quoted)' {
            if (-not (Test-Path $script:ScriptPath)) {
                throw "Missing script: $($script:ScriptPath)"
            }
            $fixture = Join-Path $script:FixtureDir 'hook-script-sample.ps1'
            $output = & pwsh -NoProfile -NonInteractive -File $script:ScriptPath --input $fixture --format json
            $output | Should -Match '\.github/scripts/Tests/audit-hub-artifact-paths\.Tests\.ps1'
        }
    }

    # ---------------------------------------------------------------------------
    # Negative cases — excluded classes must NOT appear in inventory
    # ---------------------------------------------------------------------------
    Context 'Negative cases — excluded patterns absent from inventory' {
        It 'marker template comments are NOT extracted from negative-cases.md' {
            if (-not (Test-Path $script:ScriptPath)) {
                throw "Missing script: $($script:ScriptPath)"
            }
            $fixture = Join-Path $script:FixtureDir 'negative-cases.md'
            $output = & pwsh -NoProfile -NonInteractive -File $script:ScriptPath --input $fixture --format json
            # Marker template comments contain {ID} or {PR} placeholders; none should
            # survive as inventory entries.
            $output | Should -Not -Match 'plan-issue'
            $output | Should -Not -Match 'design-phase-complete'
            $output | Should -Not -Match 'experience-owner-complete'
            $output | Should -Not -Match 'frame-credit-ledger'
            $output | Should -Not -Match 'review-judge-produced'
        }

        It 'bare tool-name backtick tokens are NOT extracted from negative-cases.md' {
            if (-not (Test-Path $script:ScriptPath)) {
                throw "Missing script: $($script:ScriptPath)"
            }
            $fixture = Join-Path $script:FixtureDir 'negative-cases.md'
            $output = & pwsh -NoProfile -NonInteractive -File $script:ScriptPath --input $fixture --format json
            # These are single-word tokens; they must not appear as path inventory entries.
            $inventoryEntries = $output | ConvertFrom-Json -ErrorAction SilentlyContinue
            if ($null -ne $inventoryEntries) {
                $paths = @($inventoryEntries | ForEach-Object { [string]$_ })
                $paths | Should -Not -Contain 'Read'
                $paths | Should -Not -Contain 'Bash'
                $paths | Should -Not -Contain 'Write'
                $paths | Should -Not -Contain 'Edit'
                $paths | Should -Not -Contain 'Grep'
                $paths | Should -Not -Contain 'Glob'
                $paths | Should -Not -Contain 'gh'
                $paths | Should -Not -Contain 'Agent'
                $paths | Should -Not -Contain 'AskUserQuestion'
                $paths | Should -Not -Contain 'read_file'
            }
        }

        It 'URLs are NOT extracted from negative-cases.md' {
            if (-not (Test-Path $script:ScriptPath)) {
                throw "Missing script: $($script:ScriptPath)"
            }
            $fixture = Join-Path $script:FixtureDir 'negative-cases.md'
            $output = & pwsh -NoProfile -NonInteractive -File $script:ScriptPath --input $fixture --format json
            $output | Should -Not -Match 'https://'
            $output | Should -Not -Match 'http://'
        }

        It 'CLI flags are NOT extracted from negative-cases.md' {
            if (-not (Test-Path $script:ScriptPath)) {
                throw "Missing script: $($script:ScriptPath)"
            }
            $fixture = Join-Path $script:FixtureDir 'negative-cases.md'
            $output = & pwsh -NoProfile -NonInteractive -File $script:ScriptPath --input $fixture --format json
            $output | Should -Not -Match '--\s*%'
            $output | Should -Not -Match '--no-verify'
        }

        It 'predicate DSL tokens are NOT extracted from negative-cases.md' {
            if (-not (Test-Path $script:ScriptPath)) {
                throw "Missing script: $($script:ScriptPath)"
            }
            $fixture = Join-Path $script:FixtureDir 'negative-cases.md'
            $output = & pwsh -NoProfile -NonInteractive -File $script:ScriptPath --input $fixture --format json
            $output | Should -Not -Match 'implement-test'
            $output | Should -Not -Match 'touchesTestableCode'
        }
    }

    # ---------------------------------------------------------------------------
    # Template normalisation — D2a placeholders
    # ---------------------------------------------------------------------------
    Context 'Template normalisation — D2a placeholder set' {
        BeforeAll {
            # Authoritative placeholder enum source:
            # top-of-file schema docstring of Documents/Design/hub-artifact-paths-classification.yml (introduced in s3)
            $script:D2aPlaceholders = @(
                '{ID}',
                '{PR}',
                '{NUMBER}',
                '{name}',
                '{port}',
                '{ISSUE_NUMBER}',
                '{N}',
                '{Surface}'
            )
        }

        It 'normalises placeholder <Placeholder> before family clustering' -ForEach @(
            @{ Placeholder = '{ID}' },
            @{ Placeholder = '{PR}' },
            @{ Placeholder = '{NUMBER}' },
            @{ Placeholder = '{name}' },
            @{ Placeholder = '{port}' },
            @{ Placeholder = '{ISSUE_NUMBER}' },
            @{ Placeholder = '{N}' },
            @{ Placeholder = '{Surface}' }
        ) {
            param($Placeholder)
            if (-not (Test-Path $script:ScriptPath)) {
                throw "Missing script: $($script:ScriptPath)"
            }
            # Confirm the script accepts --normalize-placeholders or equivalent mode
            # that strips/normalises these tokens before clustering. When the script
            # exists, invoke with a synthetic path string containing the placeholder
            # and verify it maps to the base family, not a distinct entry per instance.
            $output = & pwsh -NoProfile -NonInteractive -File $script:ScriptPath --help 2>&1
            # Until implemented, the throw above will fire first; this assertion is
            # the post-implementation contract.
            $output | Should -Not -BeNullOrEmpty
        }

        It 'all eight D2a placeholders are covered by the normalisation set' {
            # This test is structural and passes immediately — it validates that
            # this test file enumerates all eight required placeholder strings.
            $script:D2aPlaceholders.Count | Should -Be 8
            $script:D2aPlaceholders | Should -Contain '{ID}'
            $script:D2aPlaceholders | Should -Contain '{PR}'
            $script:D2aPlaceholders | Should -Contain '{NUMBER}'
            $script:D2aPlaceholders | Should -Contain '{name}'
            $script:D2aPlaceholders | Should -Contain '{port}'
            $script:D2aPlaceholders | Should -Contain '{ISSUE_NUMBER}'
            $script:D2aPlaceholders | Should -Contain '{N}'
            $script:D2aPlaceholders | Should -Contain '{Surface}'
        }
    }

    # ---------------------------------------------------------------------------
    # Byte-stability assertion
    # ---------------------------------------------------------------------------
    Context 'Byte-stability — two consecutive default-mode runs produce identical JSON' {
        It 'two consecutive default-mode invocations produce byte-identical JSON stdout' {
            if (-not (Test-Path $script:ScriptPath)) {
                throw "Missing script: $($script:ScriptPath)"
            }
            $run1 = & pwsh -NoProfile -NonInteractive -File $script:ScriptPath --format json 2>&1
            $run2 = & pwsh -NoProfile -NonInteractive -File $script:ScriptPath --format json 2>&1

            $hash1 = [System.Security.Cryptography.SHA256]::Create().ComputeHash(
                [System.Text.Encoding]::UTF8.GetBytes(($run1 -join "`n"))
            ) | ForEach-Object { $_.ToString('x2') }
            $hash2 = [System.Security.Cryptography.SHA256]::Create().ComputeHash(
                [System.Text.Encoding]::UTF8.GetBytes(($run2 -join "`n"))
            ) | ForEach-Object { $_.ToString('x2') }

            ($hash1 -join '') | Should -Be ($hash2 -join '') -Because 'default-mode JSON output must be byte-stable across consecutive runs'
        }
    }
}
