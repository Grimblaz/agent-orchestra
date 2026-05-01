#Requires -Version 7.0
<#
.SYNOPSIS
    Generates synthetic JSONL fixture sets for cost-walker.Tests.ps1 (issue #467, Step 2).
.DESCRIPTION
    Produces three fixture sets documenting per-event filter invariants:
      1. single-session-clean.jsonl  — 3 matching + 1 wrong-branch + 1 user + Agent dispatch
      2. multi-branch-session.jsonl  — two branches; only branch-A events are included
      3. partial-session.jsonl       — dangling tool_use (no matching tool_result)
    Subagent transcripts for Agent dispatches are placed in {dir}/subagents/agent-{id}.jsonl.

    INVARIANTS (documented for test consumers):
      - All events in single-session-clean with type=assistant and gitBranch=feature/branch-a
        should be included by Invoke-CostTranscriptWalk when -Branch=feature/branch-a
      - The single 'wrong-branch' event MUST be excluded
      - The single 'user' event MUST be skipped silently
      - The Agent tool_use in the included assistant triggers subagent transcript load
      - multi-branch-session: 2 branch-a events included, 2 branch-b events excluded
      - partial-session: 1 included assistant with tool_use but no tool_result in the file
#>

[CmdletBinding()]
param(
    [string]$OutputDir = $PSScriptRoot
)

$ErrorActionPreference = 'Stop'

function Write-Jsonl {
    param([string]$Path, [object[]]$Events)
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path $dir)) { $null = New-Item -ItemType Directory -Path $dir -Force }
    $Events | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 10 } | Set-Content -Path $Path -Encoding utf8NoBOM
}

$TestCwd    = '/c/test/repo'
$BranchA    = 'feature/branch-a'
$BranchB    = 'feature/branch-b'

# ---- Fixture 1: single-session-clean ----
# Three matching assistant events, one wrong-branch, one user, one Agent dispatch

$agentToolUseId = '11111111-1111-1111-1111-111111111111'

$singleSessionEvents = @(
    # 1. matching assistant
    [ordered]@{
        type      = 'assistant'
        uuid      = 'aaaaaaaa-0001-0000-0000-000000000001'
        timestamp = '2026-01-01T10:00:00Z'
        cwd       = $TestCwd
        gitBranch = $BranchA
        message   = @{
            usage   = @{ input_tokens = 100; output_tokens = 50; cache_creation_input_tokens = 0; cache_read_input_tokens = 0 }
            content = @()
        }
    }
    # 2. matching assistant with Agent tool_use
    [ordered]@{
        type      = 'assistant'
        uuid      = 'aaaaaaaa-0001-0000-0000-000000000002'
        timestamp = '2026-01-01T10:01:00Z'
        cwd       = $TestCwd
        gitBranch = $BranchA
        message   = @{
            usage   = @{ input_tokens = 200; output_tokens = 80; cache_creation_input_tokens = 10; cache_read_input_tokens = 5 }
            content = @(
                @{
                    type  = 'tool_use'
                    id    = $agentToolUseId
                    name  = 'Agent'
                    input = @{ prompt = 'Implement step 2' }
                }
            )
        }
    }
    # 3. matching assistant (third)
    [ordered]@{
        type      = 'assistant'
        uuid      = 'aaaaaaaa-0001-0000-0000-000000000003'
        timestamp = '2026-01-01T10:05:00Z'
        cwd       = $TestCwd
        gitBranch = $BranchA
        message   = @{
            usage   = @{ input_tokens = 50; output_tokens = 20; cache_creation_input_tokens = 0; cache_read_input_tokens = 50 }
            content = @()
        }
    }
    # 4. wrong-branch assistant — MUST be excluded
    [ordered]@{
        type      = 'assistant'
        uuid      = 'aaaaaaaa-0001-0000-0000-000000000004'
        timestamp = '2026-01-01T10:06:00Z'
        cwd       = $TestCwd
        gitBranch = $BranchB
        message   = @{
            usage   = @{ input_tokens = 30; output_tokens = 10; cache_creation_input_tokens = 0; cache_read_input_tokens = 0 }
            content = @()
        }
    }
    # 5. user event — MUST be skipped silently
    [ordered]@{
        type      = 'user'
        uuid      = 'aaaaaaaa-0001-0000-0000-000000000005'
        timestamp = '2026-01-01T10:07:00Z'
        content   = 'Please review the output.'
    }
)

Write-Jsonl -Path (Join-Path $OutputDir 'single-session-clean.jsonl') -Events $singleSessionEvents

# Subagent transcript for the Agent dispatch above
$subagentEvents = @(
    [ordered]@{
        type      = 'assistant'
        uuid      = 'bbbbbbbb-0001-0000-0000-000000000001'
        timestamp = '2026-01-01T10:02:00Z'
        message   = @{
            usage   = @{ input_tokens = 500; output_tokens = 300; cache_creation_input_tokens = 20; cache_read_input_tokens = 100 }
            content = @()
        }
    }
    [ordered]@{
        type      = 'assistant'
        uuid      = 'bbbbbbbb-0001-0000-0000-000000000002'
        timestamp = '2026-01-01T10:03:00Z'
        message   = @{
            usage   = @{ input_tokens = 200; output_tokens = 150; cache_creation_input_tokens = 0; cache_read_input_tokens = 200 }
            content = @()
        }
    }
)

$subagentDir = Join-Path $OutputDir 'subagents'
Write-Jsonl -Path (Join-Path $subagentDir "agent-$agentToolUseId.jsonl") -Events $subagentEvents

# ---- Fixture 2: multi-branch-session ----
# Events from two branches interleaved; only branch-A included

$multiBranchEvents = @(
    [ordered]@{
        type      = 'assistant'
        uuid      = 'cccccccc-0001-0000-0000-000000000001'
        timestamp = '2026-01-01T11:00:00Z'
        cwd       = $TestCwd
        gitBranch = $BranchA
        message   = @{ usage = @{ input_tokens = 100; output_tokens = 50; cache_creation_input_tokens = 0; cache_read_input_tokens = 0 }; content = @() }
    }
    [ordered]@{
        type      = 'assistant'
        uuid      = 'cccccccc-0001-0000-0000-000000000002'
        timestamp = '2026-01-01T11:01:00Z'
        cwd       = $TestCwd
        gitBranch = $BranchB
        message   = @{ usage = @{ input_tokens = 80; output_tokens = 30; cache_creation_input_tokens = 0; cache_read_input_tokens = 0 }; content = @() }
    }
    [ordered]@{
        type      = 'assistant'
        uuid      = 'cccccccc-0001-0000-0000-000000000003'
        timestamp = '2026-01-01T11:02:00Z'
        cwd       = $TestCwd
        gitBranch = $BranchA
        message   = @{ usage = @{ input_tokens = 120; output_tokens = 60; cache_creation_input_tokens = 5; cache_read_input_tokens = 10 }; content = @() }
    }
    [ordered]@{
        type      = 'assistant'
        uuid      = 'cccccccc-0001-0000-0000-000000000004'
        timestamp = '2026-01-01T11:03:00Z'
        cwd       = $TestCwd
        gitBranch = $BranchB
        message   = @{ usage = @{ input_tokens = 90; output_tokens = 40; cache_creation_input_tokens = 0; cache_read_input_tokens = 0 }; content = @() }
    }
)

Write-Jsonl -Path (Join-Path $OutputDir 'multi-branch-session.jsonl') -Events $multiBranchEvents

# ---- Fixture 3: partial-session ----
# Dangling tool_use with no matching tool_result — for completeness testing in Step 7

$danglingToolUseId = '22222222-2222-2222-2222-222222222222'

$partialSessionEvents = @(
    # Included assistant with a dangling non-Agent tool_use (no tool_result follows)
    [ordered]@{
        type      = 'assistant'
        uuid      = 'dddddddd-0001-0000-0000-000000000001'
        timestamp = '2026-01-01T12:00:00Z'
        cwd       = $TestCwd
        gitBranch = $BranchA
        message   = @{
            usage   = @{ input_tokens = 150; output_tokens = 70; cache_creation_input_tokens = 0; cache_read_input_tokens = 0 }
            content = @(
                @{
                    type  = 'tool_use'
                    id    = $danglingToolUseId
                    name  = 'Bash'
                    input = @{ command = 'ls' }
                }
            )
        }
    }
    # No tool_result for $danglingToolUseId — intentionally absent to test Step 7 completeness checks
)

Write-Jsonl -Path (Join-Path $OutputDir 'partial-session.jsonl') -Events $partialSessionEvents

Write-Host "Fixtures generated in: $OutputDir"
Write-Host "  single-session-clean.jsonl  (3 branch-a + 1 wrong-branch + 1 user + Agent dispatch)"
Write-Host "  subagents/agent-$agentToolUseId.jsonl  (2 subagent events)"
Write-Host "  multi-branch-session.jsonl  (2 branch-a + 2 branch-b)"
Write-Host "  partial-session.jsonl       (1 matching with dangling tool_use)"
