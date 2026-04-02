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
    excluding the Tests/ subdirectory. Update these tests only when the underlying safety
    contract intentionally changes.
#>

Describe 'script safety contract' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:ScriptsRoot = Join-Path -Path $script:RepoRoot -ChildPath '.github' -AdditionalChildPath 'scripts'
        $script:AggregateReviewScores = Join-Path $script:ScriptsRoot 'aggregate-review-scores.ps1'
        $script:AggregateReviewScoresCore = Join-Path $script:ScriptsRoot 'lib\aggregate-review-scores-core.ps1'

        $script:ProductionScripts = Get-ChildItem -Path $script:ScriptsRoot -Recurse -Filter '*.ps1' |
            Where-Object { $_.DirectoryName -notmatch '[/\\]Tests([/\\]|$)' }

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
                'branch-authority-gate.Tests.ps1',
                'script-safety-contract.Tests.ps1',   # self-excluded: this file contains the literal '& pwsh' in its own scan pattern, which would cause a false-positive match
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
