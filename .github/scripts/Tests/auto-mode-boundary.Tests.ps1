#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
.SYNOPSIS
    Contract tests for the auto-mode boundary directive in CLAUDE.md.

.DESCRIPTION
    Locks the auto-mode boundary contract established in issue #546:
        - CLAUDE.md owns a sentinel-wrapped canonical directive.
        - 11 Claude-specific surfaces cite it via root-anchored anchor.
        - Forbidden phrasing that contradicts the directive is absent.
        - The manual verification recipe is structurally sound.
        - The session-startup allowlist references only Bash (not PowerShell) for pwsh cleanup.
        - The allowlist section carries a #548 forward-reference.

    These tests are RED coverage for issue #546 steps s1-s4. Run after each
    implementation step to confirm the expected assertions pass.
#>

Describe 'auto-mode boundary contract' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path

        $script:ClaudemdPath    = Join-Path $script:RepoRoot 'CLAUDE.md'
        $script:SkillAllowlist  = Join-Path $script:RepoRoot 'skills/session-startup/SKILL.md'

        $script:CitationSurfaces = @(
            'agents/code-conductor.md',
            'agents/experience-owner.md',
            'agents/solution-designer.md',
            'agents/issue-planner.md',
            'commands/experience.md',
            'commands/design.md',
            'commands/plan.md',
            'skills/upstream-onboarding/platforms/claude.md',
            'skills/customer-experience/platforms/claude.md',
            'skills/design-exploration/platforms/claude.md',
            'skills/session-startup/platforms/claude.md'
        )

        $script:BeginSentinel  = '<!-- auto-mode-boundary:begin -->'
        $script:EndSentinel    = '<!-- auto-mode-boundary:end -->'
        $script:RecipeBegin    = '<!-- auto-mode-boundary-recipe:begin -->'
        $script:RecipeEnd      = '<!-- auto-mode-boundary-recipe:end -->'
        $script:CitationAnchor = '/CLAUDE.md#auto-mode-boundary'

        $script:ForbiddenLiterals = @(
            'skip in auto-mode',
            'skip in auto mode',
            'minimize prompts when auto',
            'minimize prompts in auto-mode',
            "don't ask in auto-mode",
            'auto-mode means don''t ask'
        )

        # Negative-lookbehind patterns: tolerate citation prose "does not suppress `AskUserQuestion`"
        # and "does not silence `AskUserQuestion`" while catching contradictory bare and backtick-wrapped forms.
        # The \s+`? makes the patterns match both "suppress AskUserQuestion" and "suppress `AskUserQuestion`".
        $script:ForbiddenPatterns = @(
            '(?<!does not )suppress\s+`?AskUserQuestion`?',
            '(?<!Auto-mode does not )silence\s+`?AskUserQuestion`?'
        )

        $script:RiskyCommandWhitelist = @(
            'gh pr merge --admin'
        )

        # Helper: read file content or return empty string on failure
        $script:ReadFile = {
            param([string]$Path)
            if (-not (Test-Path $Path)) { return '' }
            try { return (Get-Content -Path $Path -Raw -ErrorAction Stop) }
            catch { return '' }
        }

        # Helper: extract text between two sentinel strings (exclusive)
        $script:ExtractBetween = {
            param([string]$Content, [string]$Begin, [string]$End)
            $startIdx = $Content.IndexOf($Begin, [System.StringComparison]::Ordinal)
            if ($startIdx -lt 0) { return $null }
            $afterBegin = $startIdx + $Begin.Length
            $endIdx = $Content.IndexOf($End, $afterBegin, [System.StringComparison]::Ordinal)
            if ($endIdx -lt 0) { return $null }
            return $Content.Substring($afterBegin, $endIdx - $afterBegin)
        }

        # Helper: count non-overlapping occurrences of a literal string
        $script:CountOccurrences = {
            param([string]$Haystack, [string]$Needle)
            $count = 0
            $idx   = 0
            while (($found = $Haystack.IndexOf($Needle, $idx, [System.StringComparison]::Ordinal)) -ge 0) {
                $count++
                $idx = $found + $Needle.Length
            }
            return $count
        }

        $script:ClaudemdContent  = & $script:ReadFile -Path $script:ClaudemdPath
        $script:SkillContent     = & $script:ReadFile -Path $script:SkillAllowlist
    }

    # ─────────────────────────────────────────────────────────────
    # 1. Sentinel block presence (exactly one begin+end pair)
    # ─────────────────────────────────────────────────────────────
    It 'CLAUDE.md contains exactly one auto-mode-boundary sentinel block' {
        $content = $script:ClaudemdContent
        $content | Should -Not -BeNullOrEmpty -Because 'CLAUDE.md must exist and be non-empty'

        $beginCount = & $script:CountOccurrences -Haystack $content -Needle $script:BeginSentinel
        $endCount   = & $script:CountOccurrences -Haystack $content -Needle $script:EndSentinel

        $beginCount | Should -Be 1 -Because 'CLAUDE.md must contain exactly one auto-mode-boundary:begin sentinel'
        $endCount   | Should -Be 1 -Because 'CLAUDE.md must contain exactly one auto-mode-boundary:end sentinel'

        $beginIdx = $content.IndexOf($script:BeginSentinel, [System.StringComparison]::Ordinal)
        $endIdx   = $content.IndexOf($script:EndSentinel,   [System.StringComparison]::Ordinal)
        ($beginIdx -lt $endIdx) | Should -BeTrue -Because 'auto-mode-boundary:begin must precede auto-mode-boundary:end'
    }

    It 'auto-mode-boundary begin sentinel is owned by the Auto-mode boundary H2 before the next H2' {
        $content = $script:ClaudemdContent
        $sectionMatch = [regex]::Match(
            $content,
            '(?ms)^## Auto-mode boundary\s*\r?\n(?<body>.*?)(?=^## |\z)'
        )

        $sectionMatch.Success | Should -BeTrue `
            -Because 'CLAUDE.md must contain the ## Auto-mode boundary H2 section'
        $sectionMatch.Groups['body'].Value | Should -Match ([regex]::Escape($script:BeginSentinel)) `
            -Because 'auto-mode-boundary:begin must remain under ## Auto-mode boundary before the next H2'
    }

    # ─────────────────────────────────────────────────────────────
    # 2. Citation presence in 11 surfaces (root-anchored form)
    # ─────────────────────────────────────────────────────────────
    It 'each of the 11 citation surfaces contains /CLAUDE.md#auto-mode-boundary' {
        foreach ($rel in $script:CitationSurfaces) {
            $fullPath = Join-Path $script:RepoRoot $rel
            $fullPath | Should -Exist -Because "$rel must exist as a citation surface"
            $content = & $script:ReadFile -Path $fullPath
            $content | Should -Match ([regex]::Escape($script:CitationAnchor)) `
                -Because "$rel must contain the root-anchored citation $($script:CitationAnchor)"
        }
    }

    # ─────────────────────────────────────────────────────────────
    # 3. No relative-path form on citation lines
    # ─────────────────────────────────────────────────────────────
    It 'no citation line uses a relative path form (../ or ./)' {
        foreach ($rel in $script:CitationSurfaces) {
            $fullPath = Join-Path $script:RepoRoot $rel
            if (-not (Test-Path $fullPath)) { continue }
            $content = & $script:ReadFile -Path $fullPath
            $lines   = $content -split '\r?\n'
            foreach ($line in $lines) {
                if ($line -match [regex]::Escape($script:CitationAnchor)) {
                    # \.\.[/\\] catches ../ anywhere; (?:^|[([ \t])\.[/\\] catches ./ at start of line,
                    # after (, [, or whitespace — covering bare paths AND inline markdown link targets.
                    $line | Should -Not -Match '\.\.[/\\]|(?:^|[([ \t])\.[/\\]' `
                        -Because "${rel}: citation lines must use root-anchored form, not relative paths"
                }
            }
        }
    }

    # ─────────────────────────────────────────────────────────────
    # 4. Forbidden-phrase scan (with negative-lookbehind tolerance)
    # ─────────────────────────────────────────────────────────────
    It 'no forbidden phrase appears outside the directive and recipe sentinel blocks' {
        # Collect scan targets: agents/, skills/, commands/, CLAUDE.md
        $scanDirs = @('agents', 'skills', 'commands') | ForEach-Object {
            Join-Path $script:RepoRoot $_
        }
        $scanFiles = [System.Collections.Generic.List[string]]::new()
        foreach ($dir in $scanDirs) {
            if (Test-Path $dir) {
                Get-ChildItem -Path $dir -Recurse -Filter '*.md' -ErrorAction SilentlyContinue |
                    ForEach-Object { $scanFiles.Add($_.FullName) }
            }
        }
        $scanFiles.Add($script:ClaudemdPath)

        # Build allowlist regions from CLAUDE.md sentinel blocks (directive + recipe)
        $directiveInner = & $script:ExtractBetween -Content $script:ClaudemdContent `
            -Begin $script:BeginSentinel -End $script:EndSentinel
        $recipeInner    = & $script:ExtractBetween -Content $script:ClaudemdContent `
            -Begin $script:RecipeBegin -End $script:RecipeEnd

        foreach ($filePath in $scanFiles) {
            $raw = & $script:ReadFile -Path $filePath
            if ([string]::IsNullOrEmpty($raw)) { continue }

            # For CLAUDE.md: strip sentinel blocks before scanning
            $effective = $raw
            if ($filePath -eq $script:ClaudemdPath) {
                if ($null -ne $directiveInner) {
                    $effective = $effective.Replace($script:BeginSentinel + $directiveInner + $script:EndSentinel, '')
                }
                if ($null -ne $recipeInner) {
                    $effective = $effective.Replace($script:RecipeBegin + $recipeInner + $script:RecipeEnd, '')
                }
            }

            $relPath = $filePath.Replace($script:RepoRoot, '').TrimStart([IO.Path]::DirectorySeparatorChar, '/')

            foreach ($literal in $script:ForbiddenLiterals) {
                $effective | Should -Not -Match ('(?i)' + [regex]::Escape($literal)) `
                    -Because "$relPath must not contain the forbidden phrase '$literal'"
            }

            foreach ($pattern in $script:ForbiddenPatterns) {
                $effective | Should -Not -Match $pattern `
                    -Because "$relPath must not match the forbidden pattern '$pattern'"
            }
        }
    }

    # ─────────────────────────────────────────────────────────────
    # 5. Self-test for the forbidden-phrase regex
    # ─────────────────────────────────────────────────────────────
    Describe 'forbidden-phrase regex self-tests' {

        It 'tolerates the citation prose "Auto-mode does not suppress AskUserQuestion"' {
            $safe = 'Auto-mode does not suppress AskUserQuestion.'
            $safe | Should -Not -Match '(?<!does not )suppress\s+`?AskUserQuestion`?' `
                -Because 'negative lookbehind must allow the citation prose'
        }

        It 'catches the bare contradictory phrase "The agent should suppress AskUserQuestion in auto-mode"' {
            $bad = 'The agent should suppress AskUserQuestion in auto-mode.'
            $bad | Should -Match '(?<!does not )suppress\s+`?AskUserQuestion`?' `
                -Because 'regex must catch bare suppress without the negation prefix'
        }

        It 'catches the backtick-wrapped contradictory phrase "suppress `AskUserQuestion` in auto-mode"' {
            $bad = 'agents should suppress `AskUserQuestion` in auto-mode.'
            $bad | Should -Match '(?<!does not )suppress\s+`?AskUserQuestion`?' `
                -Because 'regex must catch backtick-wrapped suppress (the canonical codebase form)'
        }

        It 'tolerates "Auto-mode does not suppress `AskUserQuestion`"' {
            $safe = 'Auto-mode does not suppress `AskUserQuestion`.'
            $safe | Should -Not -Match '(?<!does not )suppress\s+`?AskUserQuestion`?' `
                -Because 'negative lookbehind must allow the backtick-wrapped negated form'
        }

        It 'tolerates "Auto-mode does not silence AskUserQuestion"' {
            $safe = 'Auto-mode does not silence AskUserQuestion in any mode.'
            $safe | Should -Not -Match '(?<!Auto-mode does not )silence\s+`?AskUserQuestion`?' `
                -Because 'negative lookbehind must allow the negated form'
        }

        It 'catches bare "silence AskUserQuestion"' {
            $bad = 'Agents should silence AskUserQuestion when mode is auto.'
            $bad | Should -Match '(?<!Auto-mode does not )silence\s+`?AskUserQuestion`?' `
                -Because 'regex must catch bare silence form'
        }

        It 'catches backtick-wrapped "silence `AskUserQuestion`"' {
            $bad = 'Agents should silence `AskUserQuestion` when mode is auto.'
            $bad | Should -Match '(?<!Auto-mode does not )silence\s+`?AskUserQuestion`?' `
                -Because 'regex must catch backtick-wrapped silence form'
        }

        It 'tolerates "Auto-mode does not silence `AskUserQuestion`"' {
            $safe = 'Auto-mode does not silence `AskUserQuestion` in any mode.'
            $safe | Should -Not -Match '(?<!Auto-mode does not )silence\s+`?AskUserQuestion`?' `
                -Because 'negative lookbehind must allow the backtick-wrapped negated form'
        }
    }

    # ─────────────────────────────────────────────────────────────
    # 6. Recipe links use inline Markdown form only
    # ─────────────────────────────────────────────────────────────
    It 'all links inside the recipe sentinel block use inline Markdown form [text](path)' {
        $recipeInner = & $script:ExtractBetween -Content $script:ClaudemdContent `
            -Begin $script:RecipeBegin -End $script:RecipeEnd
        $recipeInner | Should -Not -BeNullOrEmpty `
            -Because 'CLAUDE.md must contain a recipe sentinel block for this assertion to run'

        # Reference-style links look like [text][ref] — disallow them
        $recipeInner | Should -Not -Match '\[[^\]]+\]\[[^\]]*\]' `
            -Because 'recipe links must use inline form, not reference-style [text][ref]'

        # Bare repo-relative paths (non-system, non-http) not inside markdown link syntax are disallowed.
        # System paths starting with ~ or / are allowed in backticks (they are not repo-relative links).
        # Pattern: backtick-wrapped, not starting with ~ or /, not preceded by ( or [, not followed by ) or ],
        # contains a / between non-whitespace chars, ends with a file extension.
        $recipeInner | Should -Not -Match '(?<![(\[])`(?!~|[/\\]|\w+://)[^`\s]+/[^`\s]+\.[a-zA-Z]{1,6}`(?![)\]])' `
            -Because 'recipe must wrap repo-relative paths in inline Markdown link form, not bare backtick paths'
    }

    # ─────────────────────────────────────────────────────────────
    # 7. Path-drift: every recipe link target must exist
    # ─────────────────────────────────────────────────────────────
    It 'every recipe link target references an existing repo path' {
        $recipeInner = & $script:ExtractBetween -Content $script:ClaudemdContent `
            -Begin $script:RecipeBegin -End $script:RecipeEnd
        if ([string]::IsNullOrEmpty($recipeInner)) { return }

        $linkMatches = [regex]::Matches($recipeInner, '\[[^\]]+\]\(([^)]+)\)')
        foreach ($m in $linkMatches) {
            $href = $m.Groups[1].Value.Trim()
            # Skip external URLs and anchor-only links
            if ($href -match '^https?://' -or $href -match '^#') { continue }
            # Strip query/anchor from local paths
            $localPath = ($href -split '[?#]')[0]
            # Root-anchored paths start with /
            if ($localPath.StartsWith('/')) {
                $localPath = $localPath.TrimStart('/')
            }
            $fullPath = Join-Path $script:RepoRoot $localPath
            $fullPath | Should -Exist `
                -Because "recipe link target '$href' must reference an existing repo path"
        }
    }

    # ─────────────────────────────────────────────────────────────
    # 8. Recipe risky-case command whitelist
    # ─────────────────────────────────────────────────────────────
    It 'the recipe risky case contains at least one whitelisted command' {
        $recipeInner = & $script:ExtractBetween -Content $script:ClaudemdContent `
            -Begin $script:RecipeBegin -End $script:RecipeEnd
        $recipeInner | Should -Not -BeNullOrEmpty `
            -Because 'CLAUDE.md must contain a recipe sentinel block'

        $found = $false
        foreach ($cmd in $script:RiskyCommandWhitelist) {
            if ($recipeInner -match [regex]::Escape($cmd)) {
                $found = $true
                break
            }
        }
        $found | Should -BeTrue `
            -Because "the recipe must contain a whitelisted risky command: $($script:RiskyCommandWhitelist -join ' | ')"
    }

    # ─────────────────────────────────────────────────────────────
    # 9. Recipe Axis B existing-issue qualifier
    # ─────────────────────────────────────────────────────────────
    It 'the recipe Axis B section references an existing issue' {
        $recipeInner = & $script:ExtractBetween -Content $script:ClaudemdContent `
            -Begin $script:RecipeBegin -End $script:RecipeEnd
        $recipeInner | Should -Not -BeNullOrEmpty `
            -Because 'CLAUDE.md must contain a recipe sentinel block'

        $recipeInner | Should -Match '(?i)existing.?issue' `
            -Because 'the Axis B recipe section must anchor to an existing-issue invocation, not a greenfield prompt'
    }

    # ─────────────────────────────────────────────────────────────
    # 10. Recipe fallback prose: all 3 steps present and in order
    # ─────────────────────────────────────────────────────────────
    It 'the recipe risky case contains the three-step fallback prose in order' {
        $recipeInner = & $script:ExtractBetween -Content $script:ClaudemdContent `
            -Begin $script:RecipeBegin -End $script:RecipeEnd
        $recipeInner | Should -Not -BeNullOrEmpty `
            -Because 'CLAUDE.md must contain a recipe sentinel block'

        # Steps (word-boundary match to avoid substring false-positives like "confirmation"):
        #   1. record transcript  2. confirm allowlist  3. file an issue
        $recordMatch  = [regex]::Match($recipeInner, '\brecord\b',  [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        $confirmMatch = [regex]::Match($recipeInner, '\bconfirm\b', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        $fileMatch    = [regex]::Match($recipeInner, '\bfile\b',    [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)

        $recordMatch.Success  | Should -BeTrue -Because 'fallback step 1 (record transcript) must appear in the recipe'
        $confirmMatch.Success | Should -BeTrue -Because 'fallback step 2 (confirm allowlist) must appear in the recipe'
        $fileMatch.Success    | Should -BeTrue -Because 'fallback step 3 (file an issue) must appear in the recipe'

        ($recordMatch.Index -lt $confirmMatch.Index) | Should -BeTrue `
            -Because 'fallback step "record" must appear before "confirm"'
        ($confirmMatch.Index -lt $fileMatch.Index)   | Should -BeTrue `
            -Because 'fallback step "confirm" must appear before "file"'
    }

    # ─────────────────────────────────────────────────────────────
    # 11. Allowlist Bash-only invariant
    # ─────────────────────────────────────────────────────────────
    It 'session-startup SKILL.md uses Bash (not PowerShell) for the cleanup entry' {
        $content = $script:SkillContent
        $content | Should -Not -BeNullOrEmpty -Because 'skills/session-startup/SKILL.md must exist'

        $bashEntry        = 'Bash(pwsh*post-merge-cleanup.ps1*)'
        $psEntry          = 'PowerShell(pwsh*post-merge-cleanup.ps1*)'

        $bashCount = & $script:CountOccurrences -Haystack $content -Needle $bashEntry
        $psCount   = & $script:CountOccurrences -Haystack $content -Needle $psEntry

        ($bashCount -ge 1) | Should -BeTrue `
            -Because "SKILL.md must contain at least one '$bashEntry' allowlist entry"
        $psCount | Should -Be 0 `
            -Because "SKILL.md must not contain a '$psEntry' entry (Bash form covers pwsh on Windows)"

        # Also catch any PowerShell(...post-merge-cleanup...) variant
        $content | Should -Not -Match 'PowerShell\([^)]*post-merge-cleanup[^)]*\)' `
            -Because 'no PowerShell(...post-merge-cleanup...) variant should appear in the allowlist'
    }

    # ─────────────────────────────────────────────────────────────
    # 12. #548 forward-reference in allowlist section
    # ─────────────────────────────────────────────────────────────
    It 'session-startup SKILL.md allowlist section contains a #548 forward reference' {
        $content = $script:SkillContent
        $content | Should -Not -BeNullOrEmpty -Because 'skills/session-startup/SKILL.md must exist'

        $content | Should -Match '(#548|issues/548)' `
            -Because 'the allowlist section must carry a forward reference to issue #548'
    }

    # ─────────────────────────────────────────────────────────────
    # 13. Scope note outside sentinel blocks
    # ─────────────────────────────────────────────────────────────
    It 'the CLAUDE.md scope note "Claude Code" appears outside the directive sentinel block' {
        $content = $script:ClaudemdContent

        # Extract the H2 section content (from ## Auto-mode boundary through next ## or end)
        $sectionMatch = [regex]::Match(
            $content,
            '(?ms)^## Auto-mode boundary\s*\r?\n(?<body>.*?)(?=^## |\z)'
        )
        $sectionMatch.Success | Should -BeTrue `
            -Because 'CLAUDE.md must contain the ## Auto-mode boundary H2 section'

        $sectionBody = $sectionMatch.Groups['body'].Value

        # Extract directive block contents (to verify the scope note is NOT inside)
        $directiveInner = & $script:ExtractBetween -Content $sectionBody `
            -Begin $script:BeginSentinel -End $script:EndSentinel

        # The section body (outside sentinels) must contain "Claude Code"
        $outerBody = $sectionBody
        if ($null -ne $directiveInner) {
            $outerBody = $outerBody.Replace($script:BeginSentinel + $directiveInner + $script:EndSentinel, '')
        }
        $recipeInner = & $script:ExtractBetween -Content $outerBody `
            -Begin $script:RecipeBegin -End $script:RecipeEnd
        if ($null -ne $recipeInner) {
            $outerBody = $outerBody.Replace($script:RecipeBegin + $recipeInner + $script:RecipeEnd, '')
        }

        $outerBody | Should -Match 'Claude Code' `
            -Because 'the scope note mentioning "Claude Code" must appear in surrounding prose outside the directive sentinel'

        # If the directive inner exists, verify it does NOT contain "Claude Code" as a scope assertion
        if ($null -ne $directiveInner) {
            $directiveInner | Should -Not -Match 'Copilot uses a different permission model' `
                -Because 'the scope note about Copilot must not be inside the directive sentinel block'
        }
    }
}
