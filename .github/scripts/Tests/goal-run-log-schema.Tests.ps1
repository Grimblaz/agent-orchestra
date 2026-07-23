#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
.SYNOPSIS
    Schema-validation coverage for skills/goal-run/schemas/goal-run-log.schema.json
    (issue #874, plan step 1, AC2 item 5) -- all four entry types, including
    the optional halt_reason field on halt-claim entries.
#>

Describe 'goal-run-log.schema.json' -Tag 'unit' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:SchemaPath = Join-Path $script:RepoRoot 'skills/goal-run/schemas/goal-run-log.schema.json'
        $script:SchemaRaw = Get-Content -LiteralPath $script:SchemaPath -Raw

        function script:Test-GoalRunLogEntry {
            param([Parameter(Mandatory)][hashtable]$Entry)
            $json = $Entry | ConvertTo-Json -Depth 10
            return Test-Json -Json $json -Schema $script:SchemaRaw
        }
    }

    Context 'checkpoint entries' {
        It 'accepts a well-formed checkpoint entry' {
            $entry = @{
                schema_version = 1
                issue          = 874
                type           = 'checkpoint'
                timestamp      = '2026-07-23T01:00:00Z'
                commit_sha     = 'abc1234'
                summary        = 'Step 1 lib landed'
            }
            script:Test-GoalRunLogEntry -Entry $entry | Should -Be $true
        }

        It 'rejects a checkpoint entry missing commit_sha' {
            $entry = @{
                schema_version = 1
                issue          = 874
                type           = 'checkpoint'
                timestamp      = '2026-07-23T01:00:00Z'
                summary        = 'Step 1 lib landed'
            }
            script:Test-GoalRunLogEntry -Entry $entry | Should -Be $false
        }
    }

    Context 'deviation entries' {
        It 'accepts a well-formed deviation entry' {
            $entry = @{
                schema_version = 1
                issue          = 874
                type           = 'deviation'
                timestamp      = '2026-07-23T01:00:00Z'
                summary        = 'Skipped optional field'
                rationale      = 'Not needed for this AC'
            }
            script:Test-GoalRunLogEntry -Entry $entry | Should -Be $true
        }

        It 'rejects a deviation entry missing rationale' {
            $entry = @{
                schema_version = 1
                issue          = 874
                type           = 'deviation'
                timestamp      = '2026-07-23T01:00:00Z'
                summary        = 'Skipped optional field'
            }
            script:Test-GoalRunLogEntry -Entry $entry | Should -Be $false
        }
    }

    Context 'experience-observation entries' {
        It 'accepts a well-formed experience-observation entry' {
            $entry = @{
                schema_version = 1
                issue          = 874
                type           = 'experience-observation'
                timestamp      = '2026-07-23T01:00:00Z'
                scenario       = 'S2'
                observation    = 'CLI surface rendered as expected'
            }
            script:Test-GoalRunLogEntry -Entry $entry | Should -Be $true
        }

        It 'rejects an experience-observation entry missing scenario' {
            $entry = @{
                schema_version = 1
                issue          = 874
                type           = 'experience-observation'
                timestamp      = '2026-07-23T01:00:00Z'
                observation    = 'CLI surface rendered as expected'
            }
            script:Test-GoalRunLogEntry -Entry $entry | Should -Be $false
        }
    }

    Context 'halt-claim entries' {
        It 'accepts a well-formed halt-claim entry without halt_reason (optional field)' {
            $entry = @{
                schema_version = 1
                issue          = 874
                type           = 'halt-claim'
                timestamp      = '2026-07-23T01:00:00Z'
                summary        = 'Executor believes target is unachievable'
            }
            script:Test-GoalRunLogEntry -Entry $entry | Should -Be $true
        }

        It 'accepts a well-formed halt-claim entry WITH halt_reason' {
            $entry = @{
                schema_version = 1
                issue          = 874
                type           = 'halt-claim'
                timestamp      = '2026-07-23T01:00:00Z'
                summary        = 'Executor believes an invariant conflicts with the target'
                halt_reason    = 'invariant-conflict'
            }
            script:Test-GoalRunLogEntry -Entry $entry | Should -Be $true
        }

        It 'rejects a halt-claim entry with an out-of-enum halt_reason' {
            $entry = @{
                schema_version = 1
                issue          = 874
                type           = 'halt-claim'
                timestamp      = '2026-07-23T01:00:00Z'
                summary        = 'bogus'
                halt_reason    = 'not-a-real-reason'
            }
            script:Test-GoalRunLogEntry -Entry $entry | Should -Be $false
        }

        It 'rejects a halt-claim entry missing summary' {
            $entry = @{
                schema_version = 1
                issue          = 874
                type           = 'halt-claim'
                timestamp      = '2026-07-23T01:00:00Z'
                halt_reason    = 'budget-exhausted'
            }
            script:Test-GoalRunLogEntry -Entry $entry | Should -Be $false
        }
    }

    Context 'closed-schema and entry-type discipline' {
        It 'rejects an unknown entry type' {
            $entry = @{
                schema_version = 1
                issue          = 874
                type           = 'terminal'
                timestamp      = '2026-07-23T01:00:00Z'
            }
            script:Test-GoalRunLogEntry -Entry $entry | Should -Be $false
        }

        It 'rejects an entry carrying an undeclared extra property' {
            $entry = @{
                schema_version = 1
                issue          = 874
                type           = 'checkpoint'
                timestamp      = '2026-07-23T01:00:00Z'
                commit_sha     = 'abc1234'
                summary        = 'ok'
                extra_field    = 'not allowed'
            }
            script:Test-GoalRunLogEntry -Entry $entry | Should -Be $false
        }
    }
}
