#Requires -Version 7.0
<#
    Tests for lib/dispatch-attribution.ps1 (issue #975, D-975-2).

    Fixtures are synthetic transcript lines matching the live schema observed
    2026-08-02: assistant lines repeat per streaming chunk with identical
    message.id and growing output_tokens; the first user line carries the
    dispatched prompt including the handshake block and selector line.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot '../lib/dispatch-attribution.ps1')

    $script:FixtureDir = Join-Path $TestDrive 'subagents'
    New-Item -ItemType Directory -Path $script:FixtureDir -Force | Out-Null

    function New-TranscriptLine {
        param(
            [string]$Type,
            [string]$MsgId,
            [string]$Model = 'claude-opus-5',
            [long]$InTok = 0,
            [long]$CacheCreate = 0,
            [long]$CacheRead = 0,
            [long]$Output = 0,
            [string]$UserText,
            [object[]]$ContentBlocks,
            [string]$Timestamp = '2026-08-02T10:00:00.000Z'
        )
        if ($Type -eq 'user') {
            $obj = @{ type = 'user'; timestamp = $Timestamp; message = @{ role = 'user'; content = $UserText } }
        }
        else {
            $msg = @{
                role  = 'assistant'
                id    = $MsgId
                model = $Model
                usage = @{
                    input_tokens                = $InTok
                    cache_creation_input_tokens = $CacheCreate
                    cache_read_input_tokens     = $CacheRead
                    output_tokens               = $Output
                }
            }
            if ($ContentBlocks) { $msg.content = $ContentBlocks }
            $obj = @{ type = 'assistant'; timestamp = $Timestamp; message = $msg }
        }
        return ($obj | ConvertTo-Json -Depth 8 -Compress)
    }

    $script:PromptA = @(
        '<!-- subagent-env-handshake v1 -->'
        'parent_head: 0123456789abcdef0123456789abcdef01234567'
        'parent_branch: claude/test-branch'
        'parent_cwd: /c/Users/test/repo'
        'parent_dirty_fingerprint: e3b0c44298fc'
        'workspace_mode: shared'
        'handshake_issued_at: 2026-08-02T10:00:00.0000000Z'
        '<!-- /subagent-env-handshake -->'
        ''
        'Review mode selector: "Use code review perspectives"'
        ''
        'Shared evidence packet body here.'
        ''
        'Pass 3 lens: spec-correctness.'
    ) -join "`n"

    # PromptB shares every byte with PromptA up to the lens sentence.
    $script:PromptB = $script:PromptA.Replace('Pass 3 lens: spec-correctness.', 'Pass 4 lens: spec-security.')

    # Dispatch 1: two API messages; msg-1 streamed as two chunks (same id,
    # growing output). Includes one tool_use block.
    $d1 = @(
        New-TranscriptLine -Type user -UserText $script:PromptA -Timestamp '2026-08-02T10:00:01.000Z'
        New-TranscriptLine -Type assistant -MsgId 'msg-1' -InTok 2 -CacheCreate 21000 -CacheRead 17000 -Output 1 -Timestamp '2026-08-02T10:00:02.000Z'
        New-TranscriptLine -Type assistant -MsgId 'msg-1' -InTok 2 -CacheCreate 21000 -CacheRead 17000 -Output 150 -Timestamp '2026-08-02T10:00:03.000Z' -ContentBlocks @(
            @{ type = 'tool_use'; name = 'Read'; input = @{ file_path = 'C:/repo/agents/Code-Critic.agent.md' } }
        )
        New-TranscriptLine -Type assistant -MsgId 'msg-2' -InTok 5 -CacheCreate 100 -CacheRead 38000 -Output 900 -Timestamp '2026-08-02T10:00:10.000Z'
    ) -join "`n"
    Set-Content -LiteralPath (Join-Path $script:FixtureDir 'agent-aaa111.jsonl') -Value $d1 -Encoding utf8NoBOM

    # Dispatch 2: single API message, different selector-free prompt.
    $d2 = @(
        New-TranscriptLine -Type user -UserText $script:PromptB -Timestamp '2026-08-02T10:05:01.000Z'
        New-TranscriptLine -Type assistant -MsgId 'msg-9' -Model 'claude-sonnet-5' -InTok 3 -CacheCreate 500 -CacheRead 40000 -Output 700 -Timestamp '2026-08-02T10:05:02.000Z'
    ) -join "`n"
    Set-Content -LiteralPath (Join-Path $script:FixtureDir 'agent-bbb222.jsonl') -Value $d2 -Encoding utf8NoBOM
}

Describe 'Read-DispatchTranscript' {
    BeforeAll {
        $script:rec = Read-DispatchTranscript -Path (Join-Path $script:FixtureDir 'agent-aaa111.jsonl')
    }

    It 'derives the agent id from the filename stem' {
        $script:rec.agent_id | Should -BeExactly 'aaa111'
    }

    It 'deduplicates streaming chunks by message.id, keeping the max output_tokens' {
        $script:rec.api_calls | Should -Be 2
        $script:rec.output_tokens | Should -Be 1050   # 150 (final chunk of msg-1) + 900 (msg-2)
    }

    It 'sums per-request input and cache fields once per message id' {
        $script:rec.input_tokens | Should -Be 7                       # 2 + 5
        $script:rec.cache_creation_input_tokens | Should -Be 21100    # 21000 + 100
        $script:rec.cache_read_input_tokens | Should -Be 55000        # 17000 + 38000
    }

    It 'parses the selector line from the dispatched prompt' {
        $script:rec.selector | Should -BeExactly 'Use code review perspectives'
    }

    It 'parses handshake_issued_at from the handshake block' {
        $script:rec.handshake_issued_at | Should -BeExactly '2026-08-02T10:00:00.0000000Z'
    }

    It 'collects tool_use blocks with a bounded input summary' {
        $script:rec.tool_calls.Count | Should -Be 1
        $script:rec.tool_calls[0].tool | Should -BeExactly 'Read'
        $script:rec.tool_calls[0].input | Should -BeExactly 'C:/repo/agents/Code-Critic.agent.md'
    }

    It 'throws on a missing transcript file' {
        { Read-DispatchTranscript -Path (Join-Path $script:FixtureDir 'agent-missing.jsonl') } | Should -Throw '*not found*'
    }
}

Describe 'Read-DispatchTranscript — nonconforming rows do not abort the run' {
    BeforeAll {
        $script:RobustDir = Join-Path $TestDrive 'robust'
        New-Item -ItemType Directory -Path $script:RobustDir -Force | Out-Null

        # A user line with no `content`, and one with no `message` at all. Under
        # Set-StrictMode these are the accesses that used to throw.
        $noContent = @(
            '{"type":"user","timestamp":"2026-08-02T10:00:01.000Z","message":{"role":"user"}}'
            '{"type":"user","timestamp":"2026-08-02T10:00:02.000Z"}'
            '{"type":"user","timestamp":"2026-08-02T10:00:03.000Z","message":{"role":"user","content":"real prompt"}}'
            '{"type":"assistant","timestamp":"2026-08-02T10:00:04.000Z","message":{"role":"assistant","id":"m1","model":"claude-opus-5","usage":{"input_tokens":1,"cache_creation_input_tokens":2,"cache_read_input_tokens":3,"output_tokens":4}}}'
        ) -join "`n"
        Set-Content -LiteralPath (Join-Path $script:RobustDir 'agent-nocontent.jsonl') -Value $noContent -Encoding utf8NoBOM

        # usage present but missing three of the four token fields
        $partialUsage = @(
            '{"type":"user","timestamp":"2026-08-02T10:01:00.000Z","message":{"role":"user","content":"p"}}'
            '{"type":"assistant","timestamp":"2026-08-02T10:01:01.000Z","message":{"role":"assistant","id":"m9","model":"claude-opus-5","usage":{"input_tokens":7,"output_tokens":9}}}'
        ) -join "`n"
        Set-Content -LiteralPath (Join-Path $script:RobustDir 'agent-partialusage.jsonl') -Value $partialUsage -Encoding utf8NoBOM
    }

    It 'reads a transcript whose user lines lack content or message, and still finds the real prompt' {
        $rec = Read-DispatchTranscript -Path (Join-Path $script:RobustDir 'agent-nocontent.jsonl')
        $rec.prompt_text | Should -BeExactly 'real prompt'
        $rec.output_tokens | Should -Be 4
    }

    It 'treats absent usage token fields as zero instead of throwing' {
        $rec = Read-DispatchTranscript -Path (Join-Path $script:RobustDir 'agent-partialusage.jsonl')
        $rec.input_tokens | Should -Be 7
        $rec.output_tokens | Should -Be 9
        $rec.cache_creation_input_tokens | Should -Be 0
        $rec.cache_read_input_tokens | Should -Be 0
    }

    It 'reconstructs a prompt from content-block array form' {
        $arrayForm = @(
            '{"type":"user","timestamp":"2026-08-02T10:02:00.000Z","message":{"role":"user","content":[{"type":"text","text":"line one"},{"type":"image"},{"type":"text","text":"line two"}]}}'
        ) -join "`n"
        $p = Join-Path $script:RobustDir 'agent-arrayform.jsonl'
        Set-Content -LiteralPath $p -Value $arrayForm -Encoding utf8NoBOM
        (Read-DispatchTranscript -Path $p).prompt_text | Should -BeExactly "line one`nline two"
    }

    It 'keeps every good dispatch when one transcript in the directory is unreadable' {
        # A directory-level failure must cost the caller that file, not the batch.
        $records = Get-DispatchAttribution -TranscriptDir $script:RobustDir -WarningAction SilentlyContinue
        @($records).Count | Should -BeGreaterOrEqual 2
    }
}

Describe 'Get-DispatchAttribution' {
    It 'returns one record per transcript, sorted by first timestamp' {
        $records = Get-DispatchAttribution -TranscriptDir $script:FixtureDir
        $records.Count | Should -Be 2
        $records[0].agent_id | Should -BeExactly 'aaa111'
        $records[1].agent_id | Should -BeExactly 'bbb222'
    }

    It 'excludes dispatches older than -Since' {
        $records = @(Get-DispatchAttribution -TranscriptDir $script:FixtureDir -Since '2026-08-02T10:04:00Z')
        $records.Count | Should -Be 1
        $records[0].agent_id | Should -BeExactly 'bbb222'
    }

    It 'throws on a missing directory' {
        { Get-DispatchAttribution -TranscriptDir (Join-Path $TestDrive 'nope') } | Should -Throw '*not found*'
    }

    It 'warns rather than silently dropping when -Since excludes an unparseable timestamp' {
        $dir = Join-Path $TestDrive 'badstamp'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $dir 'agent-bad.jsonl') -Encoding utf8NoBOM -Value (
            '{"type":"user","timestamp":"not-a-date","message":{"role":"user","content":"x"}}'
        )
        $warnings = @()
        $records = Get-DispatchAttribution -TranscriptDir $dir -Since '2026-08-02T00:00:00Z' -WarningVariable warnings -WarningAction SilentlyContinue
        @($records).Count | Should -Be 0
        ($warnings -join ' ') | Should -Match 'unparseable first timestamp'
    }
}

Describe 'Format-DispatchAttributionTable' {
    It 'emits one row per dispatch plus a totals row with correct sums' {
        $records = Get-DispatchAttribution -TranscriptDir $script:FixtureDir
        $table = Format-DispatchAttributionTable -Records $records
        $rows = @($table -split "`n" | Where-Object { $_ -match '^\|' })
        $rows.Count | Should -Be 5   # header + separator + 2 dispatches + totals
        $rows[-1] | Should -Match 'total \(n=2\)'
        # totals: output 1050 + 700 = 1750; cache_read 55000 + 40000 = 95000
        $rows[-1] | Should -Match '\| 1750 \|'
        $rows[-1] | Should -Match '\| 95000 \|'
    }

    It 'escapes pipes in text cells so numeric columns cannot shift' {
        $rec = [pscustomobject]@{
            agent_id = 'a|b'; models = 'm'; selector = 'Use x | y'; api_calls = 1
            input_tokens = 1; cache_creation_input_tokens = 0; cache_read_input_tokens = 0
            output_tokens = 0; total_tokens = 1
        }
        $table = Format-DispatchAttributionTable -Records @($rec)
        $rows = @($table -split "`n" | Where-Object { $_ -match '^\|' })
        $headerCells = ($rows[0] -split '(?<!\\)\|').Count
        $dataCells = ($rows[2] -split '(?<!\\)\|').Count
        $dataCells | Should -Be $headerCells -Because 'an unescaped pipe would add columns and misalign every number'
    }
}

Describe 'Compare-DispatchPrompts' {
    It 'reports the first divergent byte offset between two prompts sharing a prefix' {
        $records = Get-DispatchAttribution -TranscriptDir $script:FixtureDir
        $cmp = @(Compare-DispatchPrompts -Records $records)
        $cmp.Count | Should -Be 1
        $cmp[0].identical | Should -BeFalse

        # Divergence begins exactly at the lens sentence.
        $expectedOffset = [System.Text.Encoding]::UTF8.GetBytes(
            $script:PromptA.Substring(0, $script:PromptA.IndexOf('Pass 3 lens'))
        ).Length + 'Pass '.Length
        $cmp[0].first_divergent_byte | Should -Be $expectedOffset
    }

    It 'reports identical=true and no divergent byte for byte-identical prompts' {
        $r1 = Read-DispatchTranscript -Path (Join-Path $script:FixtureDir 'agent-aaa111.jsonl')
        $cmp = @(Compare-DispatchPrompts -Records @($r1, $r1))
        $cmp[0].identical | Should -BeTrue
        $cmp[0].first_divergent_byte | Should -Be $null
        $cmp[0].shared_prefix_bytes | Should -Be $cmp[0].base_length_bytes
    }

    It 'requires at least two records' {
        $r1 = Read-DispatchTranscript -Path (Join-Path $script:FixtureDir 'agent-aaa111.jsonl')
        { Compare-DispatchPrompts -Records @($r1) } | Should -Throw '*at least two*'
    }
}
