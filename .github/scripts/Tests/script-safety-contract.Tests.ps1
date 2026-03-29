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

        $script:ProductionScripts = Get-ChildItem -Path $script:ScriptsRoot -Recurse -Filter '*.ps1' |
        Where-Object { $_.DirectoryName -notmatch '[/\\]Tests([/\\]|$)' }

        # Canonical taxonomy — sorted alphabetically for deterministic comparison
        $script:MandatedCategories = @(
            'architecture', 'documentation-audit', 'pattern', 'performance',
            'script-automation', 'security', 'simplicity'
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
        $content = Get-Content -Path $script:AggregateReviewScores -Raw

        $allMatches = [regex]::Matches($content, '(?s)\$knownCategories\s*=\s*@\((.*?)\)')
        $allMatches | Should -HaveCount 2 -Because '$knownCategories must be defined twice in aggregate-review-scores.ps1 (once for $accumulateFinding, once for emit loops) and both definitions must be present'

        $allMatches | ForEach-Object {
            $extractedSorted = [regex]::Matches($_.Groups[1].Value, "'([a-z-]+)'") |
            ForEach-Object { $_.Groups[1].Value } |
            Sort-Object

            ($extractedSorted -join ',') | Should -Be ($script:MandatedCategories -join ',') -Because 'every $knownCategories definition must contain exactly the 7 mandated taxonomy values (architecture, documentation-audit, pattern, performance, script-automation, security, simplicity); drift breaks cross-script consistency and calibration data integrity'
        }
    }
}
