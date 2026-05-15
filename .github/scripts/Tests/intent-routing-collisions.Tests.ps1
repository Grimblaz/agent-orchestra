#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    Fixture-shape coverage for natural-language intent routing collision examples.

.DESCRIPTION
    Locks issue #567 Step 1 collision replay prerequisites without adding Phase 2 runtime
    routing logic. The replay-budget assertion is deterministic: fixture rows are no-route
    examples, and only explicit fixture-level route_fire markers count as route fires.
#>

Describe 'Natural-language intent routing collision fixture contract' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:FixturePath = Join-Path $script:RepoRoot '.github\scripts\Tests\fixtures\intent-routing-collisions.yml'
        $script:YamlText = Get-Content -Path $script:FixturePath -Raw

        $script:ReadCollisionEntries = {
            $parsed = $script:YamlText | ConvertFrom-Yaml
            $entries = [System.Collections.Generic.List[object]]::new()

            foreach ($entry in $parsed) {
                $entries.Add($entry)
            }

            return $entries.ToArray()
        }
    }

    It 'parses the collision fixture as YAML' {
        $command = Get-Command ConvertFrom-Yaml -ErrorAction Stop
        $parsed = & $command $script:YamlText

        $parsed | Should -Not -BeNullOrEmpty
    }

    It 'contains at least fifteen collision examples' {
        $entries = @(& $script:ReadCollisionEntries)

        $entries.Count | Should -BeGreaterOrEqual 15
    }

    It 'defines phrase, no-route expectation, and class tag on every entry' {
        $entries = @(& $script:ReadCollisionEntries)

        foreach ($entry in $entries) {
            $entry.phrase | Should -BeOfType [string]
            $entry.phrase.Trim().Length | Should -BeGreaterThan 0
            $entry.no_route | Should -BeTrue
            $entry.class | Should -BeOfType [string]
            $entry.class | Should -Match '^[a-z][a-z0-9-]*$'
        }
    }

    It 'includes at least one review-overlap collision class' {
        $entries = @(& $script:ReadCollisionEntries)

        @($entries | Where-Object { $_.class -eq 'review-overlap' }).Count | Should -BeGreaterOrEqual 1
    }

    It 'keeps deterministic replay route fires within a ten-percent integer budget' {
        $entries = @(& $script:ReadCollisionEntries)
        $entries.Count | Should -BeGreaterOrEqual 10 -Because 'floor(N * 0.10) is meaningful for collision replay only when N >= 10'

        $max_route_fires = [int][Math]::Floor($entries.Count * 0.10)
        $route_fires = @($entries | Where-Object { $_.PSObject.Properties['route_fire'] -and $_.route_fire -eq $true })

        $max_route_fires | Should -BeOfType [int]
        $route_fires.Count | Should -BeLessOrEqual $max_route_fires
    }
}
