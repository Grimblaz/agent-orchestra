#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
.SYNOPSIS
    Contract tests for script safety patterns in production PowerShell scripts.

.DESCRIPTION
    Locks issue #212 W3b safety invariants:
      - Production scripts must not use Invoke-Expression or the iex alias
      - Production scripts must not call .Clone() on collections
      - $knownCategories in aggregate-review-scores.ps1 must contain exactly the 7 mandated taxonomy values

    Production scripts are defined as all .ps1 files under .github/scripts/ (root and /lib/)
    plus skill scripts under skills/**/scripts/, excluding test files. Update these
    tests only when the underlying safety contract intentionally changes.
#>

Describe 'script safety contract' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:ScriptsRoot = Join-Path -Path $script:RepoRoot -ChildPath '.github' -AdditionalChildPath 'scripts'
        $script:SkillsRoot = Join-Path -Path $script:RepoRoot -ChildPath 'skills'
        $script:AggregateReviewScores = Join-Path $script:SkillsRoot 'calibration-pipeline/scripts/aggregate-review-scores.ps1'
        $script:AggregateReviewScoresCore = Join-Path $script:SkillsRoot 'calibration-pipeline/scripts/aggregate-review-scores-core.ps1'

        $script:ProductionScripts = @(
            Get-ChildItem -Path $script:ScriptsRoot -Recurse -Filter '*.ps1' |
                Where-Object { $_.DirectoryName -notmatch '[/\\]Tests([/\\]|$)' }
                Get-ChildItem -Path $script:SkillsRoot -Recurse -Filter '*.ps1' |
                    Where-Object {
                        $_.DirectoryName -match '[/\\]scripts([/\\]|$)' -and
                        $_.DirectoryName -notmatch '[/\\]Tests([/\\]|$)'
                    }
                ) | Sort-Object -Property FullName -Unique

                # Canonical taxonomy — sorted alphabetically for deterministic comparison
                $script:MandatedCategories = @(
                    'architecture', 'documentation-audit', 'implementation-clarity',
                    'pattern', 'performance', 'script-automation', 'security'
                )
            }

            It 'script safety: production scripts must not use Invoke-Expression or iex aliases' {
                $violations = $script:ProductionScripts | Where-Object {
                    $content = Get-Content -Path $_.FullName -Raw
                    $content -match '(?i)Invoke-Expression|\biex\b'
                } | Select-Object -ExpandProperty Name

        $violations | Should -HaveCount 0 -Because 'Invoke-Expression and its iex alias allow arbitrary code execution from strings, creating command-injection risk; use explicit cmdlet calls or operator pipelines instead'
    }

    It 'script safety: production scripts must not call .Clone() on collections' {
        $violations = $script:ProductionScripts | Where-Object {
            $content = Get-Content -Path $_.FullName -Raw
            $content -match '\.Clone\(\)'
        } | Select-Object -ExpandProperty Name

        $violations | Should -HaveCount 0 -Because 'avoid all `.Clone()` to prevent accidental use on `[ordered]` hashtables where it silently drops the ordered type; use explicit copy idioms (`| ConvertTo-Json | ConvertFrom-Json -AsHashtable`) in all cases'
    }

    It 'script safety: $knownCategories in aggregate-review-scores.ps1 must contain exactly the 7 mandated values' {
        $content = Get-Content -Path $script:AggregateReviewScoresCore -Raw

        $allMatches = [regex]::Matches($content, '(?s)\$knownCategories\s*=\s*@\((.*?)\)')
        $allMatches | Should -HaveCount 2 -Because '$knownCategories must be defined twice in aggregate-review-scores.ps1 (once for $accumulateFinding, once for emit loops) and both definitions must be present'

        $allMatches | ForEach-Object {
            $extractedSorted = [regex]::Matches($_.Groups[1].Value, "'([a-z-]+)'") |
                ForEach-Object { $_.Groups[1].Value } |
                Sort-Object

                ($extractedSorted -join ',') | Should -Be ($script:MandatedCategories -join ',') -Because 'every $knownCategories definition must contain exactly the 7 mandated taxonomy values (architecture, documentation-audit, implementation-clarity, pattern, performance, script-automation, security); drift breaks cross-script consistency and calibration data integrity'
            }
        }

        It 'script safety: test files must not spawn child pwsh processes (use dot-source + in-process call pattern)' {
            $allowlist = @(
                'audit-hub-artifact-paths.Tests.ps1',      # CLI integration tests: exercises script argument-parsing entry point; dot-source pattern cannot cover CLI flag paths
                'branch-authority-gate.Tests.ps1',
                'hub-artifact-paths-coverage.Tests.ps1',   # CLI integration tests: exercises -Diff mode against live repo; requires sub-process invocation
                'script-safety-contract.Tests.ps1',        # self-excluded: this file contains the literal '& pwsh' in its own scan pattern, which would cause a false-positive match
                'session-cleanup-detector.Tests.ps1'
            )

            $violations = Get-ChildItem -Path (Join-Path $script:ScriptsRoot 'Tests') -Filter '*.Tests.ps1' |
                Where-Object { $_.Name -notin $allowlist } |
                Where-Object {
                    $content = Get-Content -Path $_.FullName -Raw
                    $content -match '& pwsh'
                } |
                Select-Object -ExpandProperty Name

        $violations | Should -HaveCount 0 -Because 'test files must use the dot-source + in-process call pattern (dot-source lib/...core.ps1, call Invoke-... directly) instead of spawning a child pwsh process per test; spawning adds significant Pester suite overhead (see issue #257)'
    }
}

Describe 'Script safety: no host-native absolute-path literals in shipped scripts' {
    It 'no .ps1 script under skills/ or .github/scripts/ constructs a Windows host-native absolute path' {
        # Tightened regex: drive letter + colon + backslash + UPPERCASE path-char
        # (?-i) forces case-sensitive matching: [A-Z] only matches uppercase, which eliminates
        # false positives from PowerShell regex-escape sequences (\s, \d, \w, \n, etc.) that use
        # lowercase meta-chars. Real Windows top-level dirs (Users, Windows, Program) start uppercase.
        # PowerShell Function:\foo PSDrive also uses lowercase after the backslash, so is excluded.
        # Exclude: full-line comments (TrimStart starts with #)
        # Exclude: lines inside block comments (<# ... #>) — e.g. .SYNOPSIS/.NOTES doc strings
        # Exclude: lines containing "# host-path-ok" allow-comment
        # Exclude: test files under */Tests/* — test fixtures may legitimately reference host paths
        # Scope: .ps1 files only under skills/ and .github/scripts/ (non-test)

        $pattern = '(?-i)[A-Za-z]:\\[A-Z][A-Za-z0-9_\\]'

        $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $searchPaths = @('skills', '.github/scripts') |
            ForEach-Object { Join-Path $repoRoot $_ } |
            Where-Object { Test-Path $_ }
        $scriptFiles = $searchPaths | ForEach-Object {
            Get-ChildItem -Path $_ -Recurse -Include '*.ps1' -File |
                Where-Object { $_.DirectoryName -notmatch '[/\\]Tests([/\\]|$)' }
        }

        $violations = [System.Collections.Generic.List[object]]::new()
        foreach ($file in $scriptFiles) {
            $lines = Get-Content $file.FullName -ErrorAction SilentlyContinue
            if (-not $lines) { continue }
            $inBlockComment = $false
            for ($i = 0; $i -lt $lines.Count; $i++) {
                $line = $lines[$i]
                # Track block comment state (<# opens, #> closes)
                if ($line -match '<#') { $inBlockComment = $true }
                if ($inBlockComment) {
                    if ($line -match '#>') { $inBlockComment = $false }
                    continue
                }
                # Skip full-line comments
                if ($line.TrimStart() -like '#*') { continue }
                # Skip lines with the allow-comment
                if ($line -match '# host-path-ok') { continue }
                # Check for the pattern
                if ($line -match $pattern) {
                    $violations.Add([PSCustomObject]@{
                        File    = $file.FullName
                        Line    = $i + 1
                        Content = $line.Trim()
                    })
                }
            }
        }

        $violations | Should -BeNullOrEmpty -Because (
            "shipped scripts must not construct Windows host-native paths (C:\...). " +
            "Use relative .tmp/ paths or /c/... git-bash form instead (see skills/terminal-hygiene/SKILL.md ## Scratch & Temp-File Hygiene). " +
            "To suppress a legitimate reference, add '# host-path-ok' on the same line."
        )
    }

    It 'the guard catches an injected C:\ literal (falsifiability check)' {
        $pattern = '(?-i)[A-Za-z]:\\[A-Z][A-Za-z0-9_\\]'
        'Get-Content "C:\Users\Foo\bar.txt"'   | Should -Match $pattern
        'Invoke-Script C:\Windows\System32\foo' | Should -Match $pattern
    }

    It 'the guard ignores common regex-escape patterns (no false positives)' {
        $pattern = '(?-i)[A-Za-z]:\\[A-Z][A-Za-z0-9_\\]'
        'checkpoints:\s*\['            | Should -Not -Match $pattern
        'Function:\gh'                 | Should -Not -Match $pattern
        'Remove-Item Function:\ -Force' | Should -Not -Match $pattern
        'pattern:\d+'                  | Should -Not -Match $pattern
        'key:\{'                       | Should -Not -Match $pattern
    }

    It 'documents the known lowercase-host-path miss (by design — trade-off documented in scratch-containment.md)' {
        # The guard intentionally misses lowercase-first-segment paths to avoid
        # false positives on regex-escape sequences (\s, \d, \w, Function:\)
        $pattern = '(?-i)[A-Za-z]:\\[A-Z][A-Za-z0-9_\\]'
        'C:\temp\foo.txt'    | Should -Not -Match $pattern -Because "lowercase host paths are a documented miss"
        'C:\dev\out.txt'     | Should -Not -Match $pattern -Because "lowercase host paths are a documented miss"
    }
}
