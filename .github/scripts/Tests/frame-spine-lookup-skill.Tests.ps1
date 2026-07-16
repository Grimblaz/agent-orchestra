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
        $script:SkillPath = Join-Path $script:RepoRoot 'skills/frame-spine-lookup/SKILL.md'
        $script:ClaudeSpecialistShellPaths = @(
            'agents/code-smith.md',
            'agents/test-writer.md',
            'agents/doc-keeper.md',
            'agents/refactor-specialist.md'
        )

        $script:CopilotSpecialistShellPaths = @(
            'agents/Code-Smith.agent.md',
            'agents/Test-Writer.agent.md',
            'agents/Doc-Keeper.agent.md',
            'agents/Refactor-Specialist.agent.md',
            'agents/Specification.agent.md',
            'agents/UI-Iterator.agent.md',
            'agents/Experience-Owner.agent.md'
        )

        # Research-Agent deferral: excluded because it has no execute/* grant; Copilot spine lookup deferred per #514 Step 12
        $script:ClaudePlatformPath = Join-Path $script:RepoRoot 'skills/frame-spine-lookup/platforms/claude.md'
        $script:CopilotPlatformPath = Join-Path $script:RepoRoot 'skills/frame-spine-lookup/platforms/copilot.md'

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
            $script:ClaudePlatformContent = & $script:ReadContent -Path $script:ClaudePlatformPath
            $script:CopilotPlatformContent = & $script:ReadContent -Path $script:CopilotPlatformPath
        }

        It 'documents fetching the plan-issue comment body through the GitHub issue comments API' {
            $script:ClaudePlatformContent | Should -Match ([regex]::Escape('gh api repos/{owner}/{repo}/issues/comments/{id}')) -Because 'Claude platform shim must document the gh api invocation for body retrieval'
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

        It 'declares the sibling comment id as a second Dispatch Input sourced from the spine, not read by the shim (863 s6, judge-sustained M5)' {
            $script:SkillContent | Should -Match '(?is)frame-slices-\{ID\}.{0,200}sibling.{0,200}slice_comment_id' -Because 'the sibling comment id must be documented as a Dispatch Input keyed off the spine''s slice_comment_id field'
            $script:SkillContent | Should -Match '(?is)specialist\s+never\s+reads?\s+`?slice_comment_id`?|never\s+by\s+reading\s+the\s+spine\s+block' -Because 'the shim must not read slice_comment_id itself — Conductor supplies it as a Dispatch Input'
        }

        It 'documents the two-fetch concatenation contract with a concrete separator and the single-fetch legacy fallback' {
            $script:SkillContent | Should -Match '(?is)concatenate.{0,200}blank\s+line' -Because 'the concatenation separator must be a concretely specified blank line, not left unspecified'
            $script:SkillContent | Should -Match '(?is)no\s+sibling\s+id\s+was\s+dispatched.{0,200}(fetch\s+only\s+the\s+plan\s+comment|single-fetch)' -Because 'legacy plans with no slice_comment_id must keep the single-fetch behavior unchanged'
        }

        It 'documents the shim-level sibling identity check and sibling-identity-mismatch failure mode' {
            $script:SkillContent | Should -Match '(?is)frame-slices-\{ID\}.{0,200}marker.{0,200}(match|matching)' -Because 'the fetched sibling must be verified against the dispatched issue number before use'
            $script:SkillContent | Should -Match 'sibling-identity-mismatch' -Because 'a mismatched or missing sibling identity marker must surface a distinct failure rather than silently proceeding'
        }

        It 'documents the two-fetch shape concretely in both the Claude and Copilot platform shims (863 s6, judge-sustained M16/M23)' {
            $script:ClaudePlatformContent | Should -Match ([regex]::Escape('gh api repos/{owner}/{repo}/issues/comments/{sibling-id}')) -Because 'the Claude shim must fetch the sibling by its own dispatched comment id'
            $script:ClaudePlatformContent | Should -Match '(?is)concatenate' -Because 'the Claude shim must document concatenating the two fetched bodies'

            Test-Path -LiteralPath $script:CopilotPlatformPath | Should -BeTrue -Because 'the Copilot platform shim file must exist'
            $script:CopilotPlatformContent | Should -Not -BeNullOrEmpty -Because 'the Copilot shim content must be readable, not just present on disk (M16 gap: previously only Test-Path was asserted)'
            $script:CopilotPlatformContent | Should -Match ([regex]::Escape('gh api repos/{owner}/{repo}/issues/comments/{sibling-id}')) -Because 'the Copilot shim must fetch the sibling by its own dispatched comment id'
            $script:CopilotPlatformContent | Should -Match '(?is)concatenate' -Because 'the Copilot shim must document concatenating the two fetched bodies'
            $script:CopilotPlatformContent | Should -Match '-CommentBodyPath' -Because 'a single gh api | pwsh pipeline cannot express two fetches; the two-fetch case must restructure to a path-based invocation on a concatenated temp file (M23)'
        }

        It 'preserves the pinned single-fetch command shape unchanged for the legacy (no-sibling) case' {
            $script:ClaudePlatformContent | Should -Match ([regex]::Escape('gh api repos/{owner}/{repo}/issues/comments/{id}')) -Because 'the singular plan-comment fetch shape must survive for the no-sibling case'
            $script:CopilotPlatformContent | Should -Match ([regex]::Escape('gh api repos/{owner}/{repo}/issues/comments/{id} --jq .body | pwsh')) -Because 'the original single-pipeline shape must survive unchanged when no sibling id is dispatched'
        }

        It 'documents Copilot spine lookup shipped in #514 and custom MCP server lookup as deferred non-goal' {
            # Copilot parity shipped in #514 - the "deferred to #514" claim must be retired
            $script:SkillContent | Should -Not -Match '(?is)Copilot\s+tool\s+shim.{0,160}deferred' -Because 'Copilot spine lookup shipped in #514; the deferred claim must be retired'
            # platforms/copilot.md must exist as evidence Copilot parity landed
            Test-Path -LiteralPath (Join-Path $script:RepoRoot 'skills/frame-spine-lookup/platforms/copilot.md') | Should -BeTrue -Because 'Copilot parity shipped in #514 requires platforms/copilot.md to exist'
            $script:SkillContent | Should -Match '(?is)custom\s+MCP\s+server.{0,160}(deferred|non-goals?|non-goal)|(deferred|non-goals?|non-goal).{0,160}custom\s+MCP\s+server' -Because 'custom MCP server work is out of scope for this skill'
        }
    }

    Context 'specialist tool grants' {

        It 'grants both Read and Bash to each Claude specialist shell that can perform lookup' {
            foreach ($relativePath in $script:ClaudeSpecialistShellPaths) {
                $shellPath = Join-Path $script:RepoRoot $relativePath
                Test-Path -LiteralPath $shellPath | Should -BeTrue -Because "$relativePath must exist"

                $content = Get-Content -LiteralPath $shellPath -Raw -ErrorAction Stop
                $frontmatter = & $script:GetFrontmatter -Content $content
                $tools = @(& $script:GetFrontmatterListField -Frontmatter $frontmatter -FieldName 'tools')

                $tools | Should -Contain 'Read' -Because "$relativePath must be able to read dispatched spine context"
                $tools | Should -Contain 'Bash' -Because "$relativePath must be able to call gh api and pwsh lookup helpers"
            }
        }

        It 'grants execute/runInTerminal or execute wildcard to each Copilot specialist agent that can perform lookup' {
            foreach ($relativePath in $script:CopilotSpecialistShellPaths) {
                $shellPath = Join-Path $script:RepoRoot $relativePath
                Test-Path -LiteralPath $shellPath | Should -BeTrue -Because "$relativePath must exist"

                $content = Get-Content -LiteralPath $shellPath -Raw -ErrorAction Stop
                $frontmatter = & $script:GetFrontmatter -Content $content

                $frontmatter | Should -Match '\bexecute\b' -Because "$relativePath must have execute/runInTerminal or execute wildcard grant for terminal-based spine lookup"
            }
        }

        It 'Research-Agent is not in the Copilot specialist list because it lacks execute/* grants (deferred to follow-up)' {
            # Research-Agent deferral: deferred to follow-up issue per Step 12 of #514
            $script:CopilotSpecialistShellPaths | Should -Not -Contain 'agents/Research-Agent.agent.md' -Because 'Research-Agent has no execute/* grant; Copilot spine lookup deferred to follow-up per #514 Step 12'
        }
    }
}
