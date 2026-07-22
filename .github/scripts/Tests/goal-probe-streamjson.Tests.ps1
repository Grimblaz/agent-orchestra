#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
.SYNOPSIS
    Coverage for Get-GoalProbeStreamJsonResult (issue #874 plan step 1, leg d).
#>

BeforeAll {
    $script:LibPath = Join-Path $PSScriptRoot '..' 'lib' 'goal-probe-streamjson.ps1'
    . $script:LibPath
}

Describe 'Get-GoalProbeStreamJsonResult' {

    Context 'satisfied outcome' {
        It 'classifies a success subtype carrying a satisfied goal-status tag' {
            $line = '{"type":"result","subtype":"success","is_error":false,"num_turns":4,"total_cost_usd":0.0123,"result":"Work is complete.\n<goal-status>satisfied</goal-status>"}'
            $result = Get-GoalProbeStreamJsonResult -Line $line
            $result | Should -Not -BeNullOrEmpty
            $result.Outcome | Should -Be 'satisfied'
            $result.TotalCostUsd | Should -Be 0.0123
            $result.NumTurns | Should -Be 4
            $result.IsError | Should -Be $false
        }
    }

    Context 'judged-impossible outcome' {
        It 'classifies a success subtype carrying an impossible goal-status tag' {
            $line = '{"type":"result","subtype":"success","is_error":false,"num_turns":9,"total_cost_usd":0.0456,"result":"Cannot proceed.\n<goal-status>impossible</goal-status>"}'
            $result = Get-GoalProbeStreamJsonResult -Line $line
            $result.Outcome | Should -Be 'judged-impossible'
            $result.NumTurns | Should -Be 9
        }
    }

    Context 'last-tag-wins' {
        It 'classifies by the LAST goal-status tag when the result text contains two different tags' {
            $line = '{"type":"result","subtype":"success","is_error":false,"num_turns":6,"total_cost_usd":0.02,"result":"First I thought <goal-status>impossible</goal-status> but then <goal-status>satisfied</goal-status>"}'
            $result = Get-GoalProbeStreamJsonResult -Line $line
            $result.Outcome | Should -Be 'satisfied'
        }
    }

    Context 'stopped outcome' {
        It 'classifies an error subtype (max turns) as stopped' {
            $line = '{"type":"result","subtype":"error_max_turns","is_error":true,"num_turns":50,"total_cost_usd":0.9,"result":""}'
            $result = Get-GoalProbeStreamJsonResult -Line $line
            $result.Outcome | Should -Be 'stopped'
            $result.Subtype | Should -Be 'error_max_turns'
        }

        It 'classifies a success subtype with no goal-status tag as stopped (protocol violation, never guessed as satisfied)' {
            $line = '{"type":"result","subtype":"success","is_error":false,"num_turns":2,"total_cost_usd":0.001,"result":"Done, no tag."}'
            $result = Get-GoalProbeStreamJsonResult -Line $line
            $result.Outcome | Should -Be 'stopped'
        }

        It 'classifies as stopped (not by the tag) when is_error is true even though a goal-status tag is present (error precedence)' {
            $line = '{"type":"result","subtype":"error_during_execution","is_error":true,"num_turns":3,"total_cost_usd":0.05,"result":"Failed partway.\n<goal-status>satisfied</goal-status>"}'
            $result = Get-GoalProbeStreamJsonResult -Line $line
            $result.Outcome | Should -Be 'stopped'
            $result.IsError | Should -Be $true
        }
    }

    Context 'is_error non-coercing hostile input' {
        It 'reports IsError as $null (not $false) and classifies as stopped when is_error is absent entirely' {
            $line = '{"type":"result","subtype":"success","num_turns":2,"total_cost_usd":0.01,"result":"Done.\n<goal-status>satisfied</goal-status>"}'
            $result = Get-GoalProbeStreamJsonResult -Line $line
            $result.IsError | Should -Be $null
            $result.Outcome | Should -Be 'stopped'
        }

        It 'reports IsError as $null (not coerced to $true) and classifies as stopped when is_error arrives as the string "false"' {
            $line = '{"type":"result","subtype":"success","is_error":"false","num_turns":2,"total_cost_usd":0.01,"result":"Done.\n<goal-status>satisfied</goal-status>"}'
            $result = Get-GoalProbeStreamJsonResult -Line $line
            $result.IsError | Should -Be $null
            $result.Outcome | Should -Be 'stopped'
        }
    }

    Context 'nullable-absent fields' {
        It 'returns $null for both TotalCostUsd and NumTurns when the result event omits them entirely' {
            $line = '{"type":"result","subtype":"success","is_error":false,"result":"Done.\n<goal-status>satisfied</goal-status>"}'
            $result = Get-GoalProbeStreamJsonResult -Line $line
            $result.TotalCostUsd | Should -Be $null
            $result.NumTurns | Should -Be $null
        }
    }

    Context 'wrong-typed field graceful degrade' {
        It 'does not throw and returns $null for total_cost_usd when it arrives as a JSON object instead of a number' {
            $line = '{"type":"result","subtype":"success","is_error":false,"num_turns":2,"total_cost_usd":{"nested":"object"},"result":"Done.\n<goal-status>satisfied</goal-status>"}'
            { Get-GoalProbeStreamJsonResult -Line $line } | Should -Not -Throw
            $result = Get-GoalProbeStreamJsonResult -Line $line
            $result.TotalCostUsd | Should -Be $null
            $result.NumTurns | Should -Be 2
        }
    }

    Context 'malformed / partial-line rejection' {
        It 'returns $null for a truncated mid-write JSONL line without throwing' {
            $partialLine = '{"type":"result","subtype":"success","is_error":false,"num_turns":3,"total_cost'
            { Get-GoalProbeStreamJsonResult -Line $partialLine } | Should -Not -Throw
            Get-GoalProbeStreamJsonResult -Line $partialLine | Should -BeNullOrEmpty
        }

        It 'returns $null for a blank or null line' {
            Get-GoalProbeStreamJsonResult -Line '' | Should -BeNullOrEmpty
            Get-GoalProbeStreamJsonResult -Line $null | Should -BeNullOrEmpty
        }

        It 'returns $null for a well-formed event of the wrong type' {
            $line = '{"type":"assistant","message":{"content":"not a result event"}}'
            Get-GoalProbeStreamJsonResult -Line $line | Should -BeNullOrEmpty
        }
    }

    Context 'non-dictionary parsed line under Set-StrictMode' {
        # Revert-sensitive coverage for the `$evt -isnot [IDictionary]` guard.
        # Under DEFAULT PowerShell these inputs are inert: indexing a scalar
        # ('hello'['type'], (5)['type']) silently yields $null, so the
        # downstream -ne 'result' check already rejects and removing the guard
        # changes nothing observable. Under Set-StrictMode -Version Latest the
        # same expressions THROW ("Cannot convert value \"type\" to type
        # \"System.Int32\"" / "Unable to index into an object of type ...").
        # Several repo lib files set StrictMode, so a strict-scope caller is a
        # real configuration -- and it is the only scope in which this guard is
        # load-bearing. Set-StrictMode is dynamically scoped, so setting it in
        # the calling scriptblock applies inside the function under test.

        It 'returns $null without throwing for a top-level JSON string line under StrictMode' {
            $line = '"hello"'
            { & { Set-StrictMode -Version Latest; Get-GoalProbeStreamJsonResult -Line $line } } | Should -Not -Throw
            & { Set-StrictMode -Version Latest; Get-GoalProbeStreamJsonResult -Line $line } | Should -BeNullOrEmpty
        }

        It 'returns $null without throwing for a top-level JSON number line under StrictMode' {
            $line = '5'
            { & { Set-StrictMode -Version Latest; Get-GoalProbeStreamJsonResult -Line $line } } | Should -Not -Throw
            & { Set-StrictMode -Version Latest; Get-GoalProbeStreamJsonResult -Line $line } | Should -BeNullOrEmpty
        }

        It 'returns $null without throwing for a top-level JSON array line under StrictMode' {
            $line = '[1,2,3]'
            { & { Set-StrictMode -Version Latest; Get-GoalProbeStreamJsonResult -Line $line } } | Should -Not -Throw
            & { Set-StrictMode -Version Latest; Get-GoalProbeStreamJsonResult -Line $line } | Should -BeNullOrEmpty
        }
    }
}
