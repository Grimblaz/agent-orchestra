#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
.SYNOPSIS
    Contract tests for Claude shell body-resolution prose.

.DESCRIPTION
    Locks the D1 body-resolution contract for issue #465. The canonical
    body-load paragraph lives in agents/code-critic.md, and every Claude shell
    must match it exactly after substituting that shell's shared-body file name.
#>

Describe 'Claude shell body-resolution contract' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:AgentsDirectory = Join-Path $script:RepoRoot 'agents'
        $script:CanonicalShellName = 'code-critic'
        $script:CanonicalBodyFile = 'Code-Critic.agent.md'
        $script:BodyLoadTokenForbiddenInShells = '${CLAUDE_PLUGIN_ROOT}'

        $script:ExpectedShells = @(
            [pscustomobject]@{ ShellName = 'code-conductor'; BodyFile = 'Code-Conductor.agent.md' }
            [pscustomobject]@{ ShellName = 'code-critic'; BodyFile = 'Code-Critic.agent.md' }
            [pscustomobject]@{ ShellName = 'code-review-response'; BodyFile = 'Code-Review-Response.agent.md' }
            [pscustomobject]@{ ShellName = 'code-smith'; BodyFile = 'Code-Smith.agent.md' }
            [pscustomobject]@{ ShellName = 'doc-keeper'; BodyFile = 'Doc-Keeper.agent.md' }
            [pscustomobject]@{ ShellName = 'experience-owner'; BodyFile = 'Experience-Owner.agent.md' }
            [pscustomobject]@{ ShellName = 'issue-planner'; BodyFile = 'Issue-Planner.agent.md' }
            [pscustomobject]@{ ShellName = 'process-review'; BodyFile = 'Process-Review.agent.md' }
            [pscustomobject]@{ ShellName = 'refactor-specialist'; BodyFile = 'Refactor-Specialist.agent.md' }
            [pscustomobject]@{ ShellName = 'research-agent'; BodyFile = 'Research-Agent.agent.md' }
            [pscustomobject]@{ ShellName = 'senior-engineer'; BodyFile = 'Senior-Engineer.agent.md' }
            [pscustomobject]@{ ShellName = 'solution-designer'; BodyFile = 'Solution-Designer.agent.md' }
            [pscustomobject]@{ ShellName = 'specification'; BodyFile = 'Specification.agent.md' }
            [pscustomobject]@{ ShellName = 'spine-runner'; BodyFile = 'Spine-Runner.agent.md' }
            [pscustomobject]@{ ShellName = 'test-writer'; BodyFile = 'Test-Writer.agent.md' }
            [pscustomobject]@{ ShellName = 'ui-iterator'; BodyFile = 'UI-Iterator.agent.md' }
        )

        $script:GetDocumentContent = {
            param([string]$Path)

            return Get-Content -Path $Path -Raw -ErrorAction Stop
        }

        $script:GetSharedMethodologySection = {
            param([string]$Content)

            $match = [regex]::Match($Content, '(?ms)^## Shared methodology\s*\r?\n(?<body>.*?)(?=^## |\z)')
            if (-not $match.Success) {
                return ''
            }

            return $match.Groups['body'].Value
        }

        $script:GetBodyPointer = {
            param([string]$SharedMethodology)

            $match = [regex]::Match($SharedMethodology, '(?m)^The full tool-agnostic methodology for this role lives at `(?<pointer>agents/[^`]+\.agent\.md)` in the repo root\.\s*$')
            if (-not $match.Success) {
                return ''
            }

            return $match.Groups['pointer'].Value
        }

        $script:GetBodyLoadParagraph = {
            param([string]$SharedMethodology)

            $match = [regex]::Match($SharedMethodology, '(?ms)^(?<paragraph>\*\*Precondition \([^)]*\):\*\*\s+.*?)(?=\r?\n\r?\n|\z)')
            if (-not $match.Success) {
                return ''
            }

            return $match.Groups['paragraph'].Value
        }

        $script:ShellDocuments = @(
            foreach ($expectedShell in $script:ExpectedShells) {
                $shellPath = Join-Path $script:AgentsDirectory ($expectedShell.ShellName + '.md')
                $shellContent = & $script:GetDocumentContent -Path $shellPath
                $sharedMethodology = & $script:GetSharedMethodologySection -Content $shellContent

                [pscustomobject]@{
                    ShellName         = $expectedShell.ShellName
                    ShellPath         = $shellPath
                    BodyFile          = $expectedShell.BodyFile
                    BodyPointer       = & $script:GetBodyPointer -SharedMethodology $sharedMethodology
                    SharedMethodology = $sharedMethodology
                    BodyLoadParagraph = & $script:GetBodyLoadParagraph -SharedMethodology $sharedMethodology
                }
            }
        )

        $script:CanonicalShell = $script:ShellDocuments |
            Where-Object { $_.ShellName -eq $script:CanonicalShellName } |
            Select-Object -First 1
        $script:CanonicalBodyLoadParagraph = $script:CanonicalShell.BodyLoadParagraph
        $script:GeneralizedCanonicalParagraph = $script:CanonicalBodyLoadParagraph.Replace($script:CanonicalBodyFile, '{Name}.agent.md')
    }

    It 'discovers exactly the 16 Claude shells covered by the body-resolution contract' {
        $expectedShellNames = @($script:ExpectedShells.ShellName | Sort-Object)
        $actualShellNames = @(
            Get-ChildItem -Path $script:AgentsDirectory -Filter '*.md' -File |
                Where-Object { $_.Name -notlike '*.agent.md' } |
                ForEach-Object { $_.BaseName } |
                Sort-Object
        )

        $actualShellNames.Count | Should -Be 16 -Because 'the D1 contract must cover all 16 Claude shell wrappers'
        $actualShellNames | Should -Be $expectedShellNames
    }

    It 'uses agents/code-critic.md as the canonical body-load paragraph source' {
        $script:CanonicalShell | Should -Not -BeNullOrEmpty
        $script:CanonicalShell.ShellPath | Should -Be (Join-Path $script:AgentsDirectory 'code-critic.md')
        $script:CanonicalShell.BodyPointer | Should -Be 'agents/Code-Critic.agent.md'
        $script:CanonicalBodyLoadParagraph | Should -Not -BeNullOrEmpty -Because 'the canonical shell must expose a body-load paragraph for the other shells to match'
    }

    It 'requires the canonical paragraph to read installed_plugins.json and its installPath for the installed plugin' {
        $script:CanonicalBodyLoadParagraph | Should -Match ([regex]::Escape('~/.claude/plugins/installed_plugins.json')) -Because 'D1 first checks the installed plugin registry'
        $script:CanonicalBodyLoadParagraph | Should -Match '(?s)(installPath.{0,160}agent-orchestra@agent-orchestra|agent-orchestra@agent-orchestra.{0,160}installPath)' -Because 'D1 must name installPath for agent-orchestra@agent-orchestra'
    }

    It 'requires the canonical paragraph to document the SemVer-sorted cache glob fallback' {
        $script:GeneralizedCanonicalParagraph | Should -Match ([regex]::Escape('SemVer-sorted')) -Because 'D1 fallback ordering must be deterministic across cache versions'
        $script:GeneralizedCanonicalParagraph | Should -Match ([regex]::Escape('~/.claude/plugins/cache/agent-orchestra/agent-orchestra/*/agents/{Name}.agent.md')) -Because 'D1 must name the plugin-cache body glob with the generalized body name'
    }

    It 'requires the canonical paragraph to gate source-repo CWD fallback on the plugin manifest name' {
        $script:CanonicalBodyLoadParagraph | Should -Match ([regex]::Escape('.claude-plugin/plugin.json')) -Because 'D1 source-repo fallback must be gated by the plugin manifest'
        $script:CanonicalBodyLoadParagraph | Should -Match ([regex]::Escape('name: agent-orchestra')) -Because 'D1 source-repo fallback must require the agent-orchestra plugin identity'
    }

    It 'requires the canonical paragraph to provide the install remediation command' {
        $script:CanonicalBodyLoadParagraph | Should -Match ([regex]::Escape('claude plugin install agent-orchestra@agent-orchestra')) -Because 'D1 broken-cache states must surface the canonical remediation command'
    }

    It 'keeps every Claude shell body-load paragraph byte-aligned with code-critic after body-name substitution' {
        foreach ($shell in $script:ShellDocuments) {
            $shell.BodyPointer | Should -Be ('agents/' + $shell.BodyFile) -Because "$($shell.ShellName) must point to its expected shared body before paragraph parity can be meaningful"
            $shell.BodyLoadParagraph | Should -Not -BeNullOrEmpty -Because "$($shell.ShellName) must expose a body-load paragraph"

            $expectedParagraph = $script:CanonicalBodyLoadParagraph.Replace($script:CanonicalBodyFile, $shell.BodyFile)
            $shell.BodyLoadParagraph | Should -BeExactly $expectedParagraph -Because "$($shell.ShellName) must byte-match the code-critic D1 paragraph after substituting its body file name"
        }
    }

    It 'rejects old standalone direct-CWD Read body loads as the only resolution path' {
        foreach ($shell in $script:ShellDocuments) {
            $directCwdLoadText = 'load `agents/' + $shell.BodyFile + '` with the `Read` tool'
            $hasOldDirectCwdLoad = $shell.BodyLoadParagraph.Contains($directCwdLoadText)
            $hasD1ResolutionPath = $shell.BodyLoadParagraph.Contains('~/.claude/plugins/installed_plugins.json') -or
            $shell.BodyLoadParagraph.Contains('~/.claude/plugins/cache/agent-orchestra/agent-orchestra/')

            ($hasOldDirectCwdLoad -and -not $hasD1ResolutionPath) | Should -BeFalse -Because "$($shell.ShellName) must not retain the retired direct-CWD Read instruction as its only body-resolution path"
        }
    }

    It 'keeps shell body-load text free of CLAUDE_PLUGIN_ROOT probes' {
        foreach ($shell in $script:ShellDocuments) {
            $shell.BodyLoadParagraph | Should -Not -Match ([regex]::Escape($script:BodyLoadTokenForbiddenInShells)) -Because "$($shell.ShellName) body-load resolution must not depend on CLAUDE_PLUGIN_ROOT"
        }
    }
}
