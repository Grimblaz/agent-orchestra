#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
.SYNOPSIS
    Issue #367 path-migration sweep gate.

.DESCRIPTION
    Verifies that .github/(agents|skills) occurrences in the repo stay within
    the active allow-list as the migration progresses. The gate narrows in
    phases as each step lands.

    Phases (controlled by $env:ISSUE_367_SWEEP_PHASE, default 'pre-mv'):
      - 'pre-mv'    : authored pre-mv (step 2); tolerates current in-scope files
      - 'post-mv'   : after step 4; agents/skills moved; old refs remain in docs
      - 'step5'     : agent Load directives + plain prose updated
      - 'step6'     : $copilotRoot runtime paths updated
      - 'step9'     : Pester test literals updated
      - 'step10'    : examples + docs updated (legacy-path fences introduced)
      - 'final'     : step 12 — zero occurrences outside the Documents/Design
                      allow-list + fenced blocks

    In every phase except 'final', the gate tolerates in-flight files awaiting
    a later step but fails on fences being unbalanced or on files that should
    already be clean regressing.
#>

BeforeDiscovery {
    # Post-merge default is 'final' — the sweep gate's post-#367 purpose is to flag any accidental
    # reintroduction of .github/(agents|skills) literals. Set ISSUE_367_SWEEP_PHASE to replay a
    # historical migration phase locally.
    $script:DiscoveryPhase = if ($env:ISSUE_367_SWEEP_PHASE) { $env:ISSUE_367_SWEEP_PHASE } else { 'final' }
}

Describe 'Issue #367 path-migration sweep gate' -Tag 'issue-367', 'sweep-gate' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:Phase = if ($env:ISSUE_367_SWEEP_PHASE) { $env:ISSUE_367_SWEEP_PHASE } else { 'final' }

        # Final allow-list (post-step-12): paths that may retain .github/(agents|skills)
        # matches forever. Glob patterns are matched with -like (where * is greedy).
        $script:FinalAllowListPatterns = @(
            'Documents/Design/*.md'
            'CUSTOMIZATION.md'
            'examples/*/copilot-instructions.md'
            '.github/scripts/Tests/path-migration-sweep-gate.Tests.ps1'
            '.github/scripts/audit-hub-artifact-paths.ps1'
            '.github/scripts/validate-architecture.ps1'
            # v1.14 upgrade guides carry legacy refs inside fenced blocks
            'README.md'
            'CONTRIBUTING.md'
            '.github/prompts/setup.prompt.md'
        )

        # Per-phase additional allow-list entries (in-flight files not yet updated).
        $script:PhaseAllowList = @{
            'pre-mv'  = @(
                '.github/agents/*.agent.md'
                '.github/skills/*'
                '.github/skills/*/*'
                '.github/skills/*/*/*'
                '.github/skills/*/*/*/*'
                '.github/scripts/Tests/*.Tests.ps1'
                '.github/scripts/validate-architecture.ps1'
                '.github/scripts/lib/*.ps1'
                '.github/prompts/*.prompt.md'
                '.github/copilot-instructions.md'
                '.github/architecture-rules.md'
                'README.md'
                'CONTRIBUTING.md'
                'examples/*/README.md'
            )
            'post-mv' = @(
                'agents/*.agent.md'
                'skills/*'
                'skills/*/*'
                'skills/*/*/*'
                'skills/*/*/*/*'
                '.github/scripts/Tests/*.Tests.ps1'
                '.github/scripts/validate-architecture.ps1'
                '.github/scripts/lib/*.ps1'
                '.github/prompts/*.prompt.md'
                '.github/copilot-instructions.md'
                '.github/architecture-rules.md'
                'README.md'
                'CONTRIBUTING.md'
                'examples/*/README.md'
            )
            'step5'   = @(
                '.github/scripts/Tests/*.Tests.ps1'
                '.github/scripts/validate-architecture.ps1'
                '.github/scripts/lib/*.ps1'
                '.github/prompts/*.prompt.md'
                '.github/copilot-instructions.md'
                '.github/architecture-rules.md'
                'README.md'
                'CONTRIBUTING.md'
                'examples/*/README.md'
                # files with $copilotRoot/.github/skills not yet updated (Step 6 owns)
                'skills/post-pr-review/SKILL.md'
                'skills/session-startup/SKILL.md'
                'skills/session-startup/scripts/*.ps1'
                'skills/guidance-measurement/scripts/*.ps1'
                'agents/Code-Conductor.agent.md'
            )
            'step6'   = @(
                '.github/scripts/Tests/*.Tests.ps1'
                '.github/scripts/validate-architecture.ps1'
                '.github/scripts/lib/*.ps1'
                '.github/prompts/*.prompt.md'
                '.github/copilot-instructions.md'
                '.github/architecture-rules.md'
                'README.md'
                'CONTRIBUTING.md'
                'examples/*/README.md'
            )
            'step9'   = @(
                '.github/scripts/validate-architecture.ps1'
                '.github/scripts/lib/*.ps1'
                '.github/prompts/*.prompt.md'
                '.github/copilot-instructions.md'
                '.github/architecture-rules.md'
                'README.md'
                'CONTRIBUTING.md'
                'examples/*/README.md'
            )
            'step10'  = @(
                '.github/architecture-rules.md'
            )
            'final'   = @()
        }

        # D3b exemption whitelist (CE Gate S3): SKILL.md files allowed to retain
        # #tool:/AskUserQuestion refs after platforms/ split.
        $script:D3bExemptSkills = @('session-startup')

        function script:Get-ActiveAllowListPatterns {
            param([string]$Phase)
            $phaseEntries = if ($script:PhaseAllowList.ContainsKey($Phase)) {
                $script:PhaseAllowList[$Phase]
            }
            else { @() }
            return $script:FinalAllowListPatterns + $phaseEntries
        }

        function script:Test-PathMatchesAnyPattern {
            param(
                [string]$RelativePath,
                [string[]]$Patterns
            )
            $normalized = $RelativePath -replace '\\', '/'
            foreach ($pattern in $Patterns) {
                $normalizedPattern = $pattern -replace '\\', '/'
                if ($normalized -like $normalizedPattern) { return $true }
            }
            return $false
        }

        # Enumerate every tracked file with a .github/(agents|skills) literal match.
        Push-Location $script:RepoRoot
        try {
            $lsFiles = (& git ls-files) -split "`n" | Where-Object { $_ }
            $script:MatchingFiles = @()
            foreach ($rel in $lsFiles) {
                $full = Join-Path $script:RepoRoot $rel
                if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { continue }
                if ($rel -match '\.(png|jpg|jpeg|gif|ico|pdf|zip|gz|tar|exe|dll)$') { continue }
                try {
                    $content = Get-Content -LiteralPath $full -Raw -ErrorAction Stop
                }
                catch { continue }
                if ($null -eq $content) { continue }
                if ($content -match '\.github[\\/](agents|skills)\b') {
                    $script:MatchingFiles += $rel
                }
            }
        }
        finally {
            Pop-Location
        }
    }

    Context 'Allow-list coverage' {
        It "All matches are within the active allow-list (phase=$script:DiscoveryPhase)" {
            $patterns = Get-ActiveAllowListPatterns -Phase $script:Phase
            $violations = @()
            foreach ($file in $script:MatchingFiles) {
                if (-not (Test-PathMatchesAnyPattern -RelativePath $file -Patterns $patterns)) {
                    $violations += $file
                }
            }
            $violations | Should -BeNullOrEmpty -Because ("Phase '{0}' should not have .github/(agents|skills) matches outside the active allow-list. Violating files:`n  {1}" -f $script:Phase, ($violations -join "`n  "))
        }
    }

    Context 'Legacy-path fence balance' {
        It 'Balanced legacy-path open/close markers' {
            $openPattern = '<!--\s*legacy-path\s*-->'
            $closePattern = '<!--\s*/legacy-path\s*-->'
            $unbalanced = @()
            foreach ($file in $script:MatchingFiles) {
                $full = Join-Path $script:RepoRoot $file
                $content = Get-Content -LiteralPath $full -Raw -ErrorAction SilentlyContinue
                if ($null -eq $content) { continue }
                $closeCount = ([regex]::Matches($content, $closePattern)).Count
                $openCount = ([regex]::Matches($content, $openPattern)).Count
                if ($openCount -ne $closeCount) {
                    $unbalanced += ('{0}: {1} open / {2} close' -f $file, $openCount, $closeCount)
                }
            }
            $unbalanced | Should -BeNullOrEmpty -Because ("Legacy-path fences must be balanced. Unbalanced:`n  {0}" -f ($unbalanced -join "`n  "))
        }
    }

    Context 'Migration-note fence balance (CUSTOMIZATION.md)' {
        It 'Balanced migration-note begin/end markers in CUSTOMIZATION.md' {
            $custom = Join-Path $script:RepoRoot 'CUSTOMIZATION.md'
            if (-not (Test-Path -LiteralPath $custom)) {
                Set-ItResult -Skipped -Because 'CUSTOMIZATION.md not present'
                return
            }
            $content = Get-Content -LiteralPath $custom -Raw
            $openCount = ([regex]::Matches($content, 'migration-note-begin\s*-->')).Count
            $closeCount = ([regex]::Matches($content, 'migration-note-end\s*-->')).Count
            $openCount | Should -Be $closeCount -Because ("CUSTOMIZATION.md migration-note fences must be balanced (have {0} begin / {1} end)" -f $openCount, $closeCount)
        }
    }

    Context 'D3b exemption whitelist (informational)' {
        It 'Exemption whitelist is documented' {
            $script:D3bExemptSkills | Should -Contain 'session-startup' -Because 'session-startup retains methodology after platforms/ split per D3b soft exemption'
        }
    }
}

Describe 'Issue #664 backslash-Join-Path hygiene gate' -Tag 'issue-664', 'sweep-gate' {
    # Gate: no tracked .ps1 file may pass a single-quoted child path containing a
    # backslash to Join-Path (e.g. Join-Path $x 'a\b') unless exempted.
    #
    # Detection regex (verbatim): Join-Path\s.*'[^'\\]+\\[^']*'
    #
    # Matches any source line where:
    #   1. The token "Join-Path" appears.
    #   2. Followed by at least one whitespace character (\s).
    #   3. Followed by any characters (.*).
    #   4. Followed by a single-quoted string whose FIRST backslash is preceded
    #      by at least one non-backslash, non-quote character ([^'\\]+) — i.e. a
    #      relative-path child argument like '..\assets\x.json' or 'lib\y.ps1'.
    #
    # Why the leading-char guard ([^'\\]+ rather than [^']*): the original
    # [^']* form let greedy .* on a Join-Path line reach forward to an unrelated
    # single-quoted regex operand later on the same line — e.g. a
    # `-replace '\s+', '-'` argument — and mis-flag it as a path violation
    # (false positive on review-completion-gate.Tests.ps1:167, issue #664 review).
    # Requiring a non-backslash char before the first backslash excludes
    # leading-backslash regex/escape literals ('\s+', '\d', '\.') while still
    # catching every relative-path literal (which never leads with a separator).
    #
    # Documented misses (outside regex scope, no known in-tree instances):
    #   - Double-quoted child paths (Join-Path $x "a\b") — regex requires a
    #     single-quoted string.
    #   - Leading-backslash single-quoted literals (Join-Path $x '\abs\path') —
    #     absolute-from-root paths; excluded by the [^'\\]+ guard above.
    #
    # Exemption mechanism (same convention as script-safety-contract.Tests.ps1):
    #   - Full-line comments (TrimStart starts with '#') are skipped.
    #   - Lines inside block comments are skipped.
    #   - Lines containing the inline comment "# host-path-ok" are skipped.
    #
    # Scope: all git-ls-files-tracked .ps1 files, Tests-inclusive,
    # excluding paths under .claude/worktrees and excluding this gate file
    # itself (self-exclusion).
    #
    # Gate invariant: AC1 = guard-green.
    # Non-goal: no conversions in this slice (s1). The gate is intentionally
    # RED after s1 until s2 (production fixes) and s3 (Tests sweep) complete.
    #
    # To suppress a legitimate reference, add '# host-path-ok' on the same line.

    BeforeAll {
        $script:RepoRoot664 = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:GatePattern = "Join-Path\s.*'[^'\\]+\\[^']*'"
        # Self-exclusion: the gate file itself contains the pattern string and
        # self-test literals — exclude it from the production scan.
        $script:GateRelPath = '.github/scripts/Tests/path-migration-sweep-gate.Tests.ps1'

        Push-Location $script:RepoRoot664
        try {
            $allTracked = (& git ls-files) -split "`n" | Where-Object { $_ }
        }
        finally {
            Pop-Location
        }

        # Scope: tracked .ps1 files, excluding .claude/worktrees, excluding gate file
        $script:ScanFiles664 = $allTracked | Where-Object {
            $_ -match '\.ps1$' -and
            $_ -notmatch '^\.claude[/\\]worktrees[/\\]' -and
            ($_ -replace '\\', '/') -ne $script:GateRelPath
        }

        $script:Violations664 = [System.Collections.Generic.List[string]]::new()
        foreach ($rel in $script:ScanFiles664) {
            $full = Join-Path $script:RepoRoot664 $rel
            if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { continue }
            $lines = Get-Content -LiteralPath $full -ErrorAction SilentlyContinue
            if (-not $lines) { continue }
            $inBlock = $false
            for ($i = 0; $i -lt $lines.Count; $i++) {
                $line = $lines[$i]
                # Track block-comment state (<# opens, #> closes)
                if ($line -match '<#') { $inBlock = $true }
                if ($inBlock) {
                    if ($line -match '#>') { $inBlock = $false }
                    continue
                }
                # Skip full-line comments
                if ($line.TrimStart() -like '#*') { continue }
                # Skip exempted lines
                if ($line -match '# host-path-ok') { continue }
                # Detect the pattern
                if ($line -match $script:GatePattern) {
                    $script:Violations664.Add(('{0}:{1}: {2}' -f $rel, ($i + 1), $line.Trim()))
                }
            }
        }
    }

    Context 'Production scan' {
        It 'No tracked .ps1 passes a backslash child path to Join-Path' {
            $script:Violations664 | Should -BeNullOrEmpty -Because (
                "Join-Path child paths must not contain backslashes — use forward slashes or " +
                "separate path segments as additional Join-Path arguments. " +
                "See .github/architecture-rules.md §Validation for the convention. " +
                "To suppress a documented Windows-only exception add '# host-path-ok' on the same line. " +
                "Violations:`n  " + ($script:Violations664 -join "`n  ")
            )
        }
    }

    Context 'Self-tests' {
        It 'Falsifiability: injected backslash child path is detected' {
            # A literal that should match the detection regex
            $injected = "Join-Path `$PSScriptRoot '..\assets\routing-config.json'"
            $injected | Should -Match $script:GatePattern
        }

        It 'No false positives: in-tree negative patterns are not flagged' {
            # Regex character class with backslash — no Join-Path prefix
            $regexClass = "if (`$rel -match '[/\\]Tests([/\\]|`$)')"
            $regexClass | Should -Not -Match $script:GatePattern

            # Content assertion with backslash — no Join-Path prefix
            $contentAssert = "`$content | Should -Be 'path\to\file'"
            $contentAssert | Should -Not -Match $script:GatePattern
        }

        It 'No false positives: a regex operand on a Join-Path line is not flagged' {
            # Regression guard (issue #664 review F1): a Join-Path with a
            # double-quoted child path AND an unrelated -replace '\s+' regex
            # operand later on the same line must NOT be flagged. The greedy
            # .* in the original [^']* form mis-matched the '\s+' literal.
            $regexOperandOnJoinPathLine = "`$path = Join-Path `$script:TempRoot (`"review-state-malformed-{0}.md`" -f (`$case.Name -replace '\s+', '-'))"
            $regexOperandOnJoinPathLine | Should -Not -Match $script:GatePattern

            # Leading-backslash literal (absolute-from-root) — documented miss
            $leadingBackslash = "Join-Path `$x '\abs\path'"
            $leadingBackslash | Should -Not -Match $script:GatePattern
        }

        It 'Documented miss: double-quoted child path is not caught by regex' {
            # Double-quoted form is the documented miss — outside regex scope
            $doubleQuoted = 'Join-Path $x "a\b.md"'
            $doubleQuoted | Should -Not -Match $script:GatePattern
        }
    }
}
