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

        $script:ConvertCollisionFixtureValue = {
            param([Parameter(Mandatory)][string]$Value)

            $trimmed = $Value.Trim()
            if ($trimmed -eq 'true') {
                return $true
            }

            if ($trimmed -eq 'false') {
                return $false
            }

            if ($trimmed -match '^"(.*)"$') {
                return ($Matches[1] -replace '\\"', '"')
            }

            return $trimmed
        }

        $script:ReadCollisionEntries = {
            $entries = [System.Collections.Generic.List[object]]::new()
            $current = $null
            $lineNumber = 0

            foreach ($line in ($script:YamlText -split "`r?`n")) {
                $lineNumber++
                if ($line.Trim().Length -eq 0) {
                    continue
                }

                if ($line -match '^\s*-\s+([a-z_]+):\s*(.+?)\s*$') {
                    if ($null -ne $current) {
                        $entries.Add([pscustomobject]$current)
                    }

                    $current = [ordered]@{}
                    $current[$Matches[1]] = & $script:ConvertCollisionFixtureValue $Matches[2]
                    continue
                }

                if ($line -match '^\s+([a-z_]+):\s*(.+?)\s*$') {
                    if ($null -eq $current) {
                        throw "Collision fixture property before first entry at line ${lineNumber}: $line"
                    }

                    $current[$Matches[1]] = & $script:ConvertCollisionFixtureValue $Matches[2]
                    continue
                }

                throw "Unsupported collision fixture line ${lineNumber}: $line"
            }

            if ($null -ne $current) {
                $entries.Add([pscustomobject]$current)
            }

            return $entries.ToArray()
        }
    }

    It 'parses the constrained collision fixture without external YAML modules' {
        $script:ParsedCollisionEntries = @()
        { $script:ParsedCollisionEntries = @(& $script:ReadCollisionEntries) } | Should -Not -Throw

        $script:ParsedCollisionEntries | Should -Not -BeNullOrEmpty
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
