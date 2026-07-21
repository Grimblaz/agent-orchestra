#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
.SYNOPSIS
    Coverage for Get-GoalProbeLiveUsageReading (issue #874 plan step 1, leg f).
#>

BeforeAll {
    $script:LibPath = Join-Path $PSScriptRoot '..' 'lib' 'goal-probe-usage-reader.ps1'
    . $script:LibPath
}

Describe 'Get-GoalProbeLiveUsageReading' {

    Context 'absent vs zero discrimination' {
        It 'reports usage-unavailable (not zero) when the usage field is absent entirely' {
            $path = Join-Path $TestDrive 'no-usage.jsonl'
            Set-Content -LiteralPath $path -Value '{"type":"assistant","message":{"content":"hi"}}' -Encoding utf8
            $result = Get-GoalProbeLiveUsageReading -TranscriptPath $path
            $result.State | Should -Be 'usage-unavailable'
            $result.Reason | Should -Be 'usage-field-absent'
            $result.LastTurnUsage | Should -BeNullOrEmpty
        }

        It 'reports usage-present-zero when usage is genuinely present and all zero' {
            $path = Join-Path $TestDrive 'zero-usage.jsonl'
            $line = '{"type":"assistant","message":{"content":"hi","usage":{"input_tokens":0,"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}'
            Set-Content -LiteralPath $path -Value $line -Encoding utf8
            $result = Get-GoalProbeLiveUsageReading -TranscriptPath $path
            $result.State | Should -Be 'usage-present-zero'
            $result.LastTurnUsage.input | Should -Be 0
        }

        It 'reports usage-present-nonzero when usage is genuinely present with real tokens' {
            $path = Join-Path $TestDrive 'nonzero-usage.jsonl'
            $line = '{"type":"assistant","message":{"content":"hi","usage":{"input_tokens":100,"output_tokens":40,"cache_creation_input_tokens":0,"cache_read_input_tokens":5}}}'
            Set-Content -LiteralPath $path -Value $line -Encoding utf8
            $result = Get-GoalProbeLiveUsageReading -TranscriptPath $path
            $result.State | Should -Be 'usage-present-nonzero'
            $result.LastTurnUsage.input | Should -Be 100
            $result.LastTurnUsage.output | Should -Be 40
        }
    }

    Context 'partial-line tolerance' {
        It 'does not throw and does not silently report zero when the tail line is truncated mid-write, falling back to the last good event' {
            $path = Join-Path $TestDrive 'partial-tail.jsonl'
            $goodLine = '{"type":"assistant","message":{"content":"hi","usage":{"input_tokens":50,"output_tokens":10,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}'
            $partialLine = '{"type":"assistant","message":{"content":"still writ'
            Set-Content -LiteralPath $path -Value @($goodLine, $partialLine) -Encoding utf8
            { Get-GoalProbeLiveUsageReading -TranscriptPath $path } | Should -Not -Throw
            $result = Get-GoalProbeLiveUsageReading -TranscriptPath $path
            $result.PartialTailDetected | Should -Be $true
            $result.State | Should -Be 'usage-present-nonzero'
            $result.LastTurnUsage.input | Should -Be 50
        }

        It 'reports usage-unavailable (not zero) when the only content is a partial tail line with no prior good event' {
            $path = Join-Path $TestDrive 'partial-only.jsonl'
            $partialLine = '{"type":"assistant","message":{"content":"still writ'
            Set-Content -LiteralPath $path -Value $partialLine -Encoding utf8
            $result = Get-GoalProbeLiveUsageReading -TranscriptPath $path
            $result.State | Should -Be 'usage-unavailable'
            $result.PartialTailDetected | Should -Be $true
            $result.Reason | Should -Be 'partial-tail-only'
        }
    }

    Context 'wrong-event-shape rejection' {
        It 'reports usage-unavailable when the usage field is present but not a dictionary shape' {
            $path = Join-Path $TestDrive 'wrong-usage-shape.jsonl'
            $line = '{"type":"assistant","message":{"content":"hi","usage":"not-an-object"}}'
            Set-Content -LiteralPath $path -Value $line -Encoding utf8
            $result = Get-GoalProbeLiveUsageReading -TranscriptPath $path
            $result.State | Should -Be 'usage-unavailable'
            $result.Reason | Should -Be 'wrong-event-shape: usage'
        }

        It 'reports usage-unavailable when the message field itself is not a dictionary shape' {
            $path = Join-Path $TestDrive 'wrong-message-shape.jsonl'
            $line = '{"type":"assistant","message":"not-an-object"}'
            Set-Content -LiteralPath $path -Value $line -Encoding utf8
            $result = Get-GoalProbeLiveUsageReading -TranscriptPath $path
            $result.State | Should -Be 'usage-unavailable'
            $result.Reason | Should -Be 'wrong-event-shape: message'
        }

        It 'reports usage-unavailable (not usage-present-zero) when usage is a dict but has none of the four canonical token keys (renamed-key shape)' {
            $path = Join-Path $TestDrive 'renamed-keys-usage.jsonl'
            $line = '{"type":"assistant","message":{"content":"hi","usage":{"inputTokens":1234}}}'
            Set-Content -LiteralPath $path -Value $line -Encoding utf8
            $result = Get-GoalProbeLiveUsageReading -TranscriptPath $path
            $result.State | Should -Be 'usage-unavailable'
            $result.Reason | Should -Be 'wrong-event-shape: usage-keys'
        }

        It 'reports usage-unavailable (not usage-present-zero) when usage is an empty dict' {
            $path = Join-Path $TestDrive 'empty-dict-usage.jsonl'
            $line = '{"type":"assistant","message":{"content":"hi","usage":{}}}'
            Set-Content -LiteralPath $path -Value $line -Encoding utf8
            $result = Get-GoalProbeLiveUsageReading -TranscriptPath $path
            $result.State | Should -Be 'usage-unavailable'
            $result.Reason | Should -Be 'wrong-event-shape: usage-keys'
        }
    }

    Context 'no-assistant-event' {
        It 'reports usage-unavailable with Reason no-assistant-event when the transcript has only non-assistant-typed events' {
            $path = Join-Path $TestDrive 'no-assistant-events.jsonl'
            $lines = @(
                '{"type":"user","message":{"content":"hi"}}',
                '{"type":"system","subtype":"init"}'
            )
            Set-Content -LiteralPath $path -Value $lines -Encoding utf8
            $result = Get-GoalProbeLiveUsageReading -TranscriptPath $path
            $result.State | Should -Be 'usage-unavailable'
            $result.Reason | Should -Be 'no-assistant-event'
        }
    }

    Context 'transcript read error' {
        It 'reports usage-unavailable with Reason transcript-read-error (not transcript-empty) when the file cannot be read due to an exclusive lock' {
            $path = Join-Path $TestDrive 'locked.jsonl'
            Set-Content -LiteralPath $path -Value 'placeholder' -Encoding utf8
            $fileStream = [System.IO.File]::Open($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::None)
            try {
                $result = Get-GoalProbeLiveUsageReading -TranscriptPath $path
                $result.State | Should -Be 'usage-unavailable'
                $result.Reason | Should -Be 'transcript-read-error'
            }
            finally {
                $fileStream.Close()
            }
        }
    }

    Context 'transcript not found / empty' {
        It 'reports usage-unavailable when the transcript path does not exist' {
            $missingPath = Join-Path $TestDrive 'does-not-exist.jsonl'
            $result = Get-GoalProbeLiveUsageReading -TranscriptPath $missingPath
            $result.State | Should -Be 'usage-unavailable'
            $result.Reason | Should -Be 'transcript-not-found'
        }

        It 'reports usage-unavailable for an empty transcript file' {
            $path = Join-Path $TestDrive 'empty.jsonl'
            New-Item -ItemType File -Path $path -Force | Out-Null
            $result = Get-GoalProbeLiveUsageReading -TranscriptPath $path
            $result.State | Should -Be 'usage-unavailable'
            $result.Reason | Should -Be 'transcript-empty'
        }
    }
}
