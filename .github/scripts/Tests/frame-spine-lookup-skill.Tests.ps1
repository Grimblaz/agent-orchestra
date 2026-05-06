#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
.SYNOPSIS
    Contract tests for the frame-spine-lookup skill.

.DESCRIPTION
    Locks the issue #512 AC6 lookup contract for the supporting methodology skill
    and verifies Claude specialist shells already expose the tool grants needed to
    perform mid-turn slice retrieval.
#>

Describe 'frame-spine-lookup skill contract' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:SkillPath = Join-Path $script:RepoRoot 'skills\frame-spine-lookup\SKILL.md'
        $script:SpecialistShellPaths = @(
            'agents/code-smith.md',
            'agents/test-writer.md',
            'agents/doc-keeper.md',
            'agents/refactor-specialist.md'
        )

        $script:ReadContent = {
            param([Parameter(Mandatory)][string]$Path)

            if (-not (Test-Path -LiteralPath $Path)) { return '' }
            return Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
        }

        $script:GetFrontmatter = {
            param([Parameter(Mandatory)][AllowEmptyString()][string]$Content)

            $match = [regex]::Match($Content, '(?ms)\A---\r?\n(?<frontmatter>.*?)\r?\n---(?:\r?\n|\z)')
            if (-not $match.Success) { return '' }
            return $match.Groups['frontmatter'].Value
        }

        $script:GetFrontmatterField = {
            param(
                [Parameter(Mandatory)][string]$Frontmatter,
                [Parameter(Mandatory)][string]$FieldName
            )

            $match = [regex]::Match($Frontmatter, "(?m)^${FieldName}:\s*(?<value>.+?)\s*$")
            if (-not $match.Success) { return $null }
            return $match.Groups['value'].Value.Trim().Trim('"').Trim("'")
        }

        $script:GetFrontmatterListField = {
            param(
                [Parameter(Mandatory)][string]$Frontmatter,
                [Parameter(Mandatory)][string]$FieldName
            )

            $fieldValue = & $script:GetFrontmatterField -Frontmatter $Frontmatter -FieldName $FieldName
            if ($null -eq $fieldValue) { return }

            $fieldValue -split ',' |
                ForEach-Object { $_.Trim() } |
                Where-Object { $_.Length -gt 0 }
        }
    }

    Context 'skill file frontmatter' {

        It 'requires the frame-spine-lookup skill file with valid discoverability frontmatter' {
            Test-Path -LiteralPath $script:SkillPath | Should -BeTrue -Because 'AC6 requires skills/frame-spine-lookup/SKILL.md to exist'

            $content = & $script:ReadContent -Path $script:SkillPath
            $frontmatter = & $script:GetFrontmatter -Content $content

            $frontmatter | Should -Not -BeNullOrEmpty -Because 'the skill must have YAML frontmatter'
            (& $script:GetFrontmatterField -Frontmatter $frontmatter -FieldName 'name') | Should -Be 'frame-spine-lookup'

            $description = & $script:GetFrontmatterField -Frontmatter $frontmatter -FieldName 'description'
            $description | Should -Match 'Use when' -Because 'the description must include positive routing language'
            $description | Should -Match 'DO NOT USE FOR' -Because 'the description must include negative routing language'
        }

        It 'does not declare provides because it is supporting methodology rather than a frame-port adapter' {
            Test-Path -LiteralPath $script:SkillPath | Should -BeTrue -Because 'AC6 requires skills/frame-spine-lookup/SKILL.md to exist'

            $content = & $script:ReadContent -Path $script:SkillPath
            $frontmatter = & $script:GetFrontmatter -Content $content

            $frontmatter | Should -Not -BeNullOrEmpty -Because 'the skill must have YAML frontmatter before its frame-adapter status can be evaluated'
            $frontmatter | Should -Not -Match '(?m)^provides\s*:' -Because 'supporting methodology skills must not claim frame port coverage'
        }
    }

    Context 'operational lookup contract' {

        BeforeAll {
            $script:SkillContent = & $script:ReadContent -Path $script:SkillPath
        }

        It 'documents fetching the plan-issue comment body through the GitHub issue comments API' {
            $script:SkillContent | Should -Match ([regex]::Escape('gh api repos/{owner}/{repo}/issues/comments/{id}')) -Because 'specialists with Bash access must fetch the plan-issue comment body by comment id'
            $script:SkillContent | Should -Match '(?is)plan-issue\s+comment\s+body' -Because 'the fetched payload must be identified as the plan-issue comment body'
        }

        It 'documents invoking frame-spine-core lookup helpers for the dispatched step id' {
            $script:SkillContent | Should -Match '(?is)pwsh\s+-File\s+.*frame-spine-core\.ps1.*-Op\s+Lookup.*-StepId\s+\{id\}' -Because 'lookup must call the production parser helper path rather than manually parsing slices'
        }

        It 'requires the dispatched spine generated_at value to participate in lookup' {
            $script:SkillContent | Should -Match '(?is)generated_at.{0,160}lookup|lookup.{0,160}generated_at' -Because 'stale-spine detection depends on comparing the dispatched spine timestamp during lookup'
        }

        It 'documents stale-spine handling after the F2.2 hash-elision filter is respected' {
            $script:SkillContent | Should -Match '(?is)generated_at.{0,120}mismatch' -Because 'lookup must detect generated_at mismatch'
            $script:SkillContent | Should -Match '(?is)F2\.2.{0,160}hash-elision\s+filter' -Because 'the stale check must respect the F2.2 hash-elision filter'
            $script:SkillContent | Should -Match '(?is)stale-spine' -Because 'the lookup result must use the stale-spine disposition'
            $script:SkillContent | Should -Match '(?is)return\s+control\s+to\s+Conductor.{0,160}re-dispatch|Conductor.{0,160}re-dispatch' -Because 'specialists must stop and let Conductor re-dispatch on stale spine'
        }

        It 'states Copilot shim and custom MCP server lookup paths are deferred non-goals' {
            $script:SkillContent | Should -Match '(?is)Copilot\s+tool\s+shim.{0,160}#514|#514.{0,160}Copilot\s+tool\s+shim' -Because 'Copilot parity is deferred to issue #514'
            $script:SkillContent | Should -Match '(?is)custom\s+MCP\s+server.{0,160}(deferred|non-goals?|non-goal)|(deferred|non-goals?|non-goal).{0,160}custom\s+MCP\s+server' -Because 'custom MCP server work is out of scope for this skill'
        }
    }

    Context 'specialist tool grants' {

        It 'grants both Read and Bash to each specialist shell that can perform lookup' {
            foreach ($relativePath in $script:SpecialistShellPaths) {
                $shellPath = Join-Path $script:RepoRoot $relativePath
                Test-Path -LiteralPath $shellPath | Should -BeTrue -Because "$relativePath must exist"

                $content = Get-Content -LiteralPath $shellPath -Raw -ErrorAction Stop
                $frontmatter = & $script:GetFrontmatter -Content $content
                $tools = @(& $script:GetFrontmatterListField -Frontmatter $frontmatter -FieldName 'tools')

                $tools | Should -Contain 'Read' -Because "$relativePath must be able to read dispatched spine context"
                $tools | Should -Contain 'Bash' -Because "$relativePath must be able to call gh api and pwsh lookup helpers"
            }
        }
    }
}
