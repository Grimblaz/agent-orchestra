# Requires -Version 7.0
# Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    Structural enforcement for per-agent model + effort routing declarations.

.DESCRIPTION
    Enforces the agent-orchestra routing convention (D9 in agent-body-architecture.md):

    - Override-discipline:    each Claude shell declares both model: and effort:, or neither.
    - Enum membership:        declared values belong to the allowed sets (case-insensitive), including explicit D7 inherit.
    - Inherit-comment:        omitting shells carry an explanatory YAML comment.
    - Routing-values oracle:  declared-routing shells match hard-coded expected values (D2+D5+quality).
    - Routing-table parity:   CLAUDE.md routing table matches shell frontmatter for oracle shells and D7 inherit rows.
    - Command enforcement D3: upstream commands (/experience /design /plan /polish) must NOT declare model/effort.
    - Command enforcement D1: commands/orchestrate.md MUST declare model: sonnet, effort: high.
    - Scope guard:            commands/orchestrate.md `# /orchestrate` H1 is permanently followed by <!-- scope: claude-only -->.

    Parser strategy: ALL frontmatter parsing uses raw-text regex against the frontmatter slice
    (content between the first pair of --- delimiters), NOT ConvertFrom-Yaml, because YAML
    comments are stripped during parse and the inherit-comment check requires them.
    Routing-table parity uses Markdown-table parsing (raw-text regex), not YAML.
#>

Describe 'Per-agent model + effort routing contract' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:AgentsDirectory = Join-Path $script:RepoRoot 'agents'
        $script:CommandsDirectory = Join-Path $script:RepoRoot 'commands'
        $script:ClaudeMdPath = Join-Path $script:RepoRoot 'CLAUDE.md'

        # Routing-values oracle: hard-coded expected routing for explicitly-declared shells.
        # code-conductor is D2 (redundant orchestrator guarantee); code-critic / code-review-response
        # are D5 (adversarial-review quality justification); refactor-specialist / process-review are
        # quality-justified Sonnet+high. All five use (Levenshtein on mismatch for diagnostics).
        $script:ExpectedRouting = @{
            'agents/code-critic.md'          = @{ model = 'opus'; effort = 'high' }
            'agents/code-review-response.md' = @{ model = 'opus'; effort = 'xhigh' }
            'agents/refactor-specialist.md'  = @{ model = 'sonnet'; effort = 'high' }
            'agents/process-review.md'       = @{ model = 'sonnet'; effort = 'high' }
            'agents/code-conductor.md'       = @{ model = 'sonnet'; effort = 'high' }
        }

        # D7: explicit inherit/inherit routing for the minimal frame walker.
        $script:D7InheritRouting = @{
            'agents/spine-runner.md' = @{ model = 'inherit'; effort = 'inherit' }
            'commands/spine-run.md'  = @{ model = 'inherit'; effort = 'inherit' }
        }

        # D1: commands/orchestrate.md required routing
        $script:RequiredCommandRouting = @{
            'commands/orchestrate.md'     = @{ model = 'sonnet'; effort = 'high' }
            'commands/code-conductor.md'  = @{ model = 'sonnet'; effort = 'high' }
            'commands/review-github.md'   = @{ model = 'sonnet'; effort = 'high' }
        }

        # D3: upstream commands that MUST NOT declare model/effort
        $script:ForbiddenCommandFiles = @(
            'commands/experience.md',
            'commands/design.md',
            'commands/plan.md',
            'commands/polish.md'
        )

        # Extract frontmatter slice (raw text between first --- pair, NOT parsed YAML)
        $script:GetFrontmatter = {
            param([string]$Content)
            $match = [regex]::Match($Content, '(?ms)\A---\r?\n(?<fm>.*?)\r?\n---')
            if (-not $match.Success) { return '' }
            return $match.Groups['fm'].Value
        }

        # Read a scalar field from the frontmatter slice via raw-text regex.
        # Trailing whitespace + optional `# comment` is permitted so YAML lines like
        # `model: sonnet  # quality-justified` parse correctly (per Gemini review).
        $script:GetFrontmatterField = {
            param([string]$Frontmatter, [string]$FieldName)
            $match = [regex]::Match($Frontmatter, "(?m)^${FieldName}:\s*(?<val>\S+)\s*(#.*)?$")
            if (-not $match.Success) { return $null }
            return $match.Groups['val'].Value.Trim()
        }

        # Check for one of the two canonical inherit-comment patterns (raw-text regex, NOT YAML)
        $script:HasInheritComment = {
            param([string]$Frontmatter)
            $routinePattern = [regex]::Escape('# model/effort intentionally omitted: inherits dispatcher per agent-orchestra routing convention')
            $inlinePattern = [regex]::Escape('# model/effort intentionally omitted: inline /experience|/design|/plan inherit user-session default')
            return ($Frontmatter -match $routinePattern) -or ($Frontmatter -match $inlinePattern)
        }

        $script:HasD7InheritComment = {
            param([string]$Frontmatter)
            return $Frontmatter -match '(?ms)^# inherit\b.*?\(D7\)\.'
        }

        $script:ReadRoutingDeclaration = {
            param([string]$RelPath)

            $path = Join-Path $script:RepoRoot $RelPath
            Test-Path $path | Should -BeTrue -Because "$RelPath must exist in the repo"

            $frontmatter = & $script:GetFrontmatter -Content (Get-Content -Path $path -Raw)
            $modelRaw = & $script:GetFrontmatterField -Frontmatter $frontmatter -FieldName 'model'
            $effortRaw = & $script:GetFrontmatterField -Frontmatter $frontmatter -FieldName 'effort'

            return [PSCustomObject]@{
                Frontmatter = $frontmatter
                Model       = if ($null -ne $modelRaw) { $modelRaw.ToLowerInvariant() } else { $null }
                Effort      = if ($null -ne $effortRaw) { $effortRaw.ToLowerInvariant() } else { $null }
            }
        }

        $script:AssertRoutingTableMatchesDeclaration = {
            param(
                [string]$RelPath,
                [PSCustomObject]$Declaration,
                [string]$ExpectationLabel
            )

            $row = $script:RoutingTable[$RelPath]
            $row | Should -Not -BeNullOrEmpty -Because "CLAUDE.md routing table must contain a row for '$RelPath'"

            $rowModel = if ($null -ne $row.model) { $row.model.ToLowerInvariant() } else { $null }
            $rowEffort = if ($null -ne $row.effort) { $row.effort.ToLowerInvariant() } else { $null }
            $rowModel  | Should -Be $Declaration.Model  -Because "CLAUDE.md table model for '$RelPath' must match $ExpectationLabel"
            $rowEffort | Should -Be $Declaration.Effort -Because "CLAUDE.md table effort for '$RelPath' must match $ExpectationLabel"
        }

        # Levenshtein distance for enum-mismatch hints
        $script:Levenshtein = {
            param([string]$A, [string]$B)
            $la = $A.Length; $lb = $B.Length
            $dp = New-Object 'int[,]' ($la + 1), ($lb + 1)
            for ($i = 0; $i -le $la; $i++) { $dp[$i, 0] = $i }
            for ($j = 0; $j -le $lb; $j++) { $dp[0, $j] = $j }
            for ($j = 1; $j -le $lb; $j++) {
                for ($i = 1; $i -le $la; $i++) {
                    $cost = if ($A[$i - 1] -ceq $B[$j - 1]) { 0 } else { 1 }
                    $dp[$i, $j] = [Math]::Min(
                        [Math]::Min($dp[$i - 1, $j] + 1, $dp[$i, $j - 1] + 1),
                        $dp[$i - 1, $j - 1] + $cost
                    )
                }
            }
            return $dp[$la, $lb]
        }

        # Find closest candidate by Levenshtein distance
        $script:FindClosest = {
            param([string]$Value, [string[]]$Candidates)
            $closest = $null
            $closestDistance = [int]::MaxValue

            foreach ($candidate in $Candidates) {
                $distance = & $script:Levenshtein -A $Value -B $candidate
                if ($distance -lt $closestDistance) {
                    $closest = $candidate
                    $closestDistance = $distance
                }
            }

            return $closest
        }

        # Parse CLAUDE.md routing table: returns hashtable keyed by shell path
        # Matches rows of the form: | `shell-path` | `model` | `effort` | ... |
        $script:ParseRoutingTable = {
            param([string]$Content)
            $sectionMatch = [regex]::Match($Content, '(?ms)^## Per-agent model \+ reasoning routing\s*\r?\n(?<body>.*?)(?=^## |\z)')
            if (-not $sectionMatch.Success) { return @{} }
            $body = $sectionMatch.Groups['body'].Value
            $rows = [regex]::Matches($body, '(?m)^\|\s*`(?<shell>[^`]+)`\s*\|\s*`(?<model>[^`]+)`\s*\|\s*`(?<effort>[^`]+)`\s*\|')
            $table = @{}
            foreach ($row in $rows) {
                $table[$row.Groups['shell'].Value] = @{
                    model  = $row.Groups['model'].Value
                    effort = $row.Groups['effort'].Value
                }
            }
            return $table
        }

        # Pre-load
        $script:ClaudeMdContent = Get-Content -Path $script:ClaudeMdPath -Raw -ErrorAction Stop
        $script:RoutingTable = & $script:ParseRoutingTable -Content $script:ClaudeMdContent

        # Recursive scan future-proofs against any subdirectory layout under agents/
        # (currently flat). The `-notlike '*.agent.md'` filter still excludes shared bodies.
        $script:ShellFiles = @(
            Get-ChildItem -Path $script:AgentsDirectory -Filter '*.md' -File -Recurse |
                Where-Object { $_.Name -notlike '*.agent.md' }
        )
    }

    It 'override-discipline: each shell declares both model and effort, or neither (both-or-neither)' {
        foreach ($shellFile in $script:ShellFiles) {
            $fm = & $script:GetFrontmatter -Content (Get-Content -Path $shellFile.FullName -Raw)
            $hasModel = $null -ne (& $script:GetFrontmatterField -Frontmatter $fm -FieldName 'model')
            $hasEffort = $null -ne (& $script:GetFrontmatterField -Frontmatter $fm -FieldName 'effort')
            ($hasModel -eq $hasEffort) | Should -BeTrue -Because (
                "$($shellFile.Name) must declare both model: and effort: together, or omit both " +
                "(both-or-neither override-discipline)"
            )
        }
    }

    It 'enum membership: declared model and effort values are in the allowed sets' {
        $validModels = @('sonnet', 'opus', 'haiku', 'inherit')
        $validEfforts = @('low', 'medium', 'high', 'xhigh', 'max', 'inherit')

        foreach ($shellFile in $script:ShellFiles) {
            $fm = & $script:GetFrontmatter -Content (Get-Content -Path $shellFile.FullName -Raw)
            $model = & $script:GetFrontmatterField -Frontmatter $fm -FieldName 'model'
            $effort = & $script:GetFrontmatterField -Frontmatter $fm -FieldName 'effort'

            if ($null -ne $model) {
                $norm = $model.ToLowerInvariant()
                if ($norm -notin $validModels) {
                    $hint = & $script:FindClosest -Value $norm -Candidates $validModels
                    $norm | Should -BeIn $validModels -Because (
                        "$($shellFile.Name): model '$norm' is not valid. " +
                        "Expected one of {sonnet|opus|haiku|inherit}. Did you mean '$hint'?"
                    )
                }
            }

            if ($null -ne $effort) {
                $norm = $effort.ToLowerInvariant()
                if ($norm -notin $validEfforts) {
                    $hint = & $script:FindClosest -Value $norm -Candidates $validEfforts
                    $norm | Should -BeIn $validEfforts -Because (
                        "$($shellFile.Name): effort '$norm' is not valid. " +
                        "Expected one of {low|medium|high|xhigh|max|inherit}. Did you mean '$hint'?"
                    )
                }
            }
        }
    }

    It 'inherit-comment: omitting shells carry an explanatory YAML comment inside frontmatter' {
        foreach ($shellFile in $script:ShellFiles) {
            $fm = & $script:GetFrontmatter -Content (Get-Content -Path $shellFile.FullName -Raw)
            $model = & $script:GetFrontmatterField -Frontmatter $fm -FieldName 'model'
            $effort = & $script:GetFrontmatterField -Frontmatter $fm -FieldName 'effort'

            if ($null -eq $model -and $null -eq $effort) {
                (& $script:HasInheritComment -Frontmatter $fm) | Should -BeTrue -Because (
                    "$($shellFile.Name) omits model/effort but is missing the required YAML " +
                    "comment explaining the inheritance (see plan step 6 for the two allowed forms)"
                )
            }
        }
    }

    It 'routing-values oracle: declared-routing shells match hard-coded expected values (D2+D5+quality)' {
        foreach ($relPath in $script:ExpectedRouting.Keys) {
            $declaration = & $script:ReadRoutingDeclaration -RelPath $relPath
            $declaration.Model  | Should -Be $script:ExpectedRouting[$relPath].model  -Because "$relPath model must match routing-values oracle"
            $declaration.Effort | Should -Be $script:ExpectedRouting[$relPath].effort -Because "$relPath effort must match routing-values oracle"
        }
    }

    It 'routing-table parity: CLAUDE.md table matches shell frontmatter for oracle shells' {
        $script:RoutingTable.Count | Should -BeGreaterThan 0 -Because (
            'CLAUDE.md must contain a parseable "## Per-agent model + reasoning routing" table'
        )

        foreach ($relPath in $script:ExpectedRouting.Keys) {
            $declaration = & $script:ReadRoutingDeclaration -RelPath $relPath
            & $script:AssertRoutingTableMatchesDeclaration `
                -RelPath $relPath `
                -Declaration $declaration `
                -ExpectationLabel 'shell frontmatter'
        }

        foreach ($relPath in $script:D7InheritRouting.Keys) {
            $declaration = & $script:ReadRoutingDeclaration -RelPath $relPath
            $declaration.Model  | Should -Be $script:D7InheritRouting[$relPath].model  -Because "$relPath model must match D7 inherit routing"
            $declaration.Effort | Should -Be $script:D7InheritRouting[$relPath].effort -Because "$relPath effort must match D7 inherit routing"
            (& $script:HasD7InheritComment -Frontmatter $declaration.Frontmatter) | Should -BeTrue -Because "$relPath must carry the D7 inherit YAML comment"
            & $script:AssertRoutingTableMatchesDeclaration `
                -RelPath $relPath `
                -Declaration $declaration `
                -ExpectationLabel 'D7 frontmatter'
        }

        # Also check orchestrate.md command row
        foreach ($relPath in $script:RequiredCommandRouting.Keys) {
            $row = $script:RoutingTable[$relPath]
            $row | Should -Not -BeNullOrEmpty -Because "CLAUDE.md routing table must contain a row for '$relPath'"
            $row.model.ToLowerInvariant()  | Should -Be $script:RequiredCommandRouting[$relPath].model  -Because "CLAUDE.md table model for '$relPath' must match required value"
            $row.effort.ToLowerInvariant() | Should -Be $script:RequiredCommandRouting[$relPath].effort -Because "CLAUDE.md table effort for '$relPath' must match required value"
        }
    }

    It 'routing-table parity: non-D7 inherit rows in CLAUDE.md must not have frontmatter model/effort' {
        $script:RoutingTable.Count | Should -BeGreaterThan 0 -Because (
            'CLAUDE.md must contain a parseable "## Per-agent model + reasoning routing" table'
        )

        foreach ($relPath in $script:RoutingTable.Keys) {
            $row = $script:RoutingTable[$relPath]
            if ($row.model -ne 'inherit') { continue }
            if ($script:D7InheritRouting.ContainsKey($relPath)) { continue }

            $shellPath = Join-Path $script:RepoRoot $relPath
            Test-Path $shellPath | Should -BeTrue -Because (
                "$relPath is listed as 'inherit' in the CLAUDE.md routing table but the file does not exist — " +
                "remove the table entry or create the shell file"
            )

            $fm = & $script:GetFrontmatter -Content (Get-Content -Path $shellPath -Raw)
            $model = & $script:GetFrontmatterField -Frontmatter $fm -FieldName 'model'
            $effort = & $script:GetFrontmatterField -Frontmatter $fm -FieldName 'effort'

            $model  | Should -BeNull -Because (
                "$relPath is listed as 'inherit' in the CLAUDE.md routing table but declares model: " +
                "in its frontmatter — remove the field or update the table"
            )
            $effort | Should -BeNull -Because (
                "$relPath is listed as 'inherit' in the CLAUDE.md routing table but declares effort: " +
                "in its frontmatter — remove the field or update the table"
            )
        }
    }

    It 'command D3: upstream commands must not declare model or effort (inherit user-session)' {
        foreach ($relPath in $script:ForbiddenCommandFiles) {
            $commandPath = Join-Path $script:RepoRoot $relPath
            Test-Path $commandPath | Should -BeTrue -Because (
                "$relPath must exist — D3 constraint cannot be verified for a missing file"
            )

            $fm = & $script:GetFrontmatter -Content (Get-Content -Path $commandPath -Raw)
            $model = & $script:GetFrontmatterField -Frontmatter $fm -FieldName 'model'
            $effort = & $script:GetFrontmatterField -Frontmatter $fm -FieldName 'effort'

            $model  | Should -BeNull -Because "$relPath must not declare model: (D3: upstream commands inherit user-session)"
            $effort | Should -BeNull -Because "$relPath must not declare effort: (D3: upstream commands inherit user-session)"
        }
    }

    It 'command D1: commands/orchestrate.md must declare model: sonnet and effort: high' {
        foreach ($relPath in $script:RequiredCommandRouting.Keys) {
            $commandPath = Join-Path $script:RepoRoot $relPath
            Test-Path $commandPath | Should -BeTrue -Because "$relPath must exist"

            $fm = & $script:GetFrontmatter -Content (Get-Content -Path $commandPath -Raw)
            $model = & $script:GetFrontmatterField -Frontmatter $fm -FieldName 'model'
            $effort = & $script:GetFrontmatterField -Frontmatter $fm -FieldName 'effort'

            $model  | Should -Not -BeNullOrEmpty -Because "$relPath must declare model: (D1)"
            $effort | Should -Not -BeNullOrEmpty -Because "$relPath must declare effort: (D1)"
            $model.ToLowerInvariant()  | Should -Be $script:RequiredCommandRouting[$relPath].model  -Because "$relPath model must match D1 required value"
            $effort.ToLowerInvariant() | Should -Be $script:RequiredCommandRouting[$relPath].effort -Because "$relPath effort must match D1 required value"
        }
    }

    It 'scope guard: orchestrate.md scope comment follows the H1 heading (permanent regression guard)' {
        # The scope marker '<!-- scope: claude-only -->' must appear immediately after the
        # `# /orchestrate` H1, separated only by blank lines. Asserted positionally relative
        # to the H1 (not at a hard-coded line index) so the test is robust to harmless edits
        # like adding/removing frontmatter fields or reflowing whitespace, while still
        # catching scope-marker removal, relocation, or text drift.
        $orchestratePath = Join-Path $script:RepoRoot 'commands/orchestrate.md'
        Test-Path $orchestratePath | Should -BeTrue -Because 'commands/orchestrate.md must exist'

        $content = Get-Content -Path $orchestratePath -Raw

        # Match opening ---, frontmatter body, closing --- and trailing newline.
        $fmMatch = [regex]::Match($content, '(?ms)\A---\r?\n.*?\r?\n---\r?\n')
        $fmMatch.Success | Should -BeTrue -Because (
            'commands/orchestrate.md must start with YAML frontmatter delimited by --- on its own lines'
        )

        $afterFm = $content.Substring($fmMatch.Length)

        # The scope comment must follow the `# /orchestrate` H1 heading with only blank
        # lines between. This is the structural invariant: H1 first, then scope marker.
        $pattern = '(?ms)^\s*\r?\n*# /orchestrate\s*\r?\n(\s*\r?\n)*<!--\s*scope:\s*claude-only\s*-->'
        $afterFm | Should -Match $pattern -Because (
            "commands/orchestrate.md must contain '# /orchestrate' as its first H1, immediately " +
            "followed (allowing only blank lines) by '<!-- scope: claude-only -->'. This positional " +
            'invariant anchors the Claude-only command-routing contract; if the scope marker has ' +
            'moved, been removed, or had its text changed, the contract is broken.'
        )
    }
}
