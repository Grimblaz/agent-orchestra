#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
.SYNOPSIS
    Coverage for .github/scripts/lib/goal-run-budget-core.ps1 (issue #874,
    plan step 7, AC1 budget half; 874-D5 arm-scoped, Arm-I default).
#>

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
    $script:LibPath = Join-Path $script:RepoRoot '.github/scripts/lib/goal-run-budget-core.ps1'
    . $script:LibPath
}

Describe 'goal-run-budget-core.ps1: lib resolves' -Tag 'unit' {
    It 'exists at the expected path' {
        (Test-Path -LiteralPath $script:LibPath) | Should -Be $true
    }
}

# ---------------------------------------------------------------------------
# 1. Session-identity registry (874-D5)
# ---------------------------------------------------------------------------

Describe 'Get-GoalRunBudgetRegistryPath' -Tag 'unit' {
    It 'resolves under the user profile, never a hardcoded literal' {
        $path = Get-GoalRunBudgetRegistryPath
        $expectedBase = if ($IsWindows) { $env:USERPROFILE } else { $HOME }
        $path | Should -Be (Join-Path $expectedBase '.claude' 'goal-run' 'session-registry.json')
    }
}

Describe 'Register-GoalRunBudgetSession + Test-GoalRunBudgetSessionRegistered' -Tag 'unit' {

    It 'registers a session and reports it registered on read-back' {
        $registryPath = Join-Path $TestDrive 'registry-a.json'
        $result = Register-GoalRunBudgetSession -SessionId 'session-armed-1' -Issue 874 -RegistryPath $registryPath
        $result.Success | Should -Be $true

        $check = Test-GoalRunBudgetSessionRegistered -SessionId 'session-armed-1' -RegistryPath $registryPath
        $check.Status | Should -Be 'registered'
        $check.Entry.issue | Should -Be 874
    }

    It 'reports not-registered for a bystander session id never written to the registry (simulates a diagnostic session in a preserved crashed worktree)' {
        $registryPath = Join-Path $TestDrive 'registry-b.json'
        Register-GoalRunBudgetSession -SessionId 'the-real-executor-session' -Issue 874 -RegistryPath $registryPath | Out-Null

        $check = Test-GoalRunBudgetSessionRegistered -SessionId 'a-diagnostic-session-poking-around' -RegistryPath $registryPath
        $check.Status | Should -Be 'not-registered'
        $check.Entry | Should -BeNullOrEmpty
    }

    It 'reports registry-missing when no registry file exists at all' {
        $registryPath = Join-Path $TestDrive 'never-created-registry.json'
        $check = Test-GoalRunBudgetSessionRegistered -SessionId 'any-session' -RegistryPath $registryPath
        $check.Status | Should -Be 'registry-missing'
    }

    It 'reports registry-unreadable when the registry file exists but is malformed' {
        $registryPath = Join-Path $TestDrive 'corrupt-registry.json'
        Set-Content -LiteralPath $registryPath -Value '{ this is not valid json' -Encoding utf8
        $check = Test-GoalRunBudgetSessionRegistered -SessionId 'any-session' -RegistryPath $registryPath
        $check.Status | Should -Be 'registry-unreadable'
    }

    It 'preserves a previously registered session when a second, different session registers afterward' {
        $registryPath = Join-Path $TestDrive 'registry-multi.json'
        Register-GoalRunBudgetSession -SessionId 'session-one' -Issue 874 -RegistryPath $registryPath | Out-Null
        Register-GoalRunBudgetSession -SessionId 'session-two' -Issue 875 -RegistryPath $registryPath | Out-Null

        (Test-GoalRunBudgetSessionRegistered -SessionId 'session-one' -RegistryPath $registryPath).Status | Should -Be 'registered'
        (Test-GoalRunBudgetSessionRegistered -SessionId 'session-two' -RegistryPath $registryPath).Status | Should -Be 'registered'
    }
}

# ---------------------------------------------------------------------------
# 2. Wall-clock arm resolution
# ---------------------------------------------------------------------------

Describe 'Resolve-GoalRunBudgetArmState' -Tag 'unit' {

    It 'arms and reports BudgetExhausted when a registered session has run past the ceiling' {
        $registryPath = Join-Path $TestDrive 'arm-exhausted.json'
        Register-GoalRunBudgetSession -SessionId 'armed-session' -Issue 874 -RegistryPath $registryPath | Out-Null

        $launchedAt = [datetime]::new(2026, 7, 23, 0, 0, 0, [System.DateTimeKind]::Utc)
        $now = $launchedAt.AddMinutes(90)

        $result = Resolve-GoalRunBudgetArmState -CurrentSessionId 'armed-session' -LaunchedAt $launchedAt `
            -CeilingMinutes 60 -Now $now -RegistryPath $registryPath

        $result.Armed | Should -Be $true
        $result.ArmReason | Should -Be 'session-registered'
        $result.BudgetExhausted | Should -Be $true
        $result.ElapsedMinutes | Should -Be 90
    }

    It 'arms but reports BudgetExhausted false when a registered session is still within the ceiling' {
        $registryPath = Join-Path $TestDrive 'arm-within.json'
        Register-GoalRunBudgetSession -SessionId 'armed-session' -Issue 874 -RegistryPath $registryPath | Out-Null

        $launchedAt = [datetime]::new(2026, 7, 23, 0, 0, 0, [System.DateTimeKind]::Utc)
        $now = $launchedAt.AddMinutes(10)

        $result = Resolve-GoalRunBudgetArmState -CurrentSessionId 'armed-session' -LaunchedAt $launchedAt `
            -CeilingMinutes 60 -Now $now -RegistryPath $registryPath

        $result.Armed | Should -Be $true
        $result.BudgetExhausted | Should -Be $false
    }

    It 'never arms for a bystander session id, even when elapsed time hugely exceeds the ceiling' {
        $registryPath = Join-Path $TestDrive 'arm-bystander.json'
        Register-GoalRunBudgetSession -SessionId 'the-real-executor-session' -Issue 874 -RegistryPath $registryPath | Out-Null

        $launchedAt = [datetime]::new(2026, 7, 23, 0, 0, 0, [System.DateTimeKind]::Utc)
        $now = $launchedAt.AddHours(50)

        $result = Resolve-GoalRunBudgetArmState -CurrentSessionId 'a-diagnostic-session-poking-around' -LaunchedAt $launchedAt `
            -CeilingMinutes 60 -Now $now -RegistryPath $registryPath

        $result.Armed | Should -Be $false
        $result.ArmReason | Should -Be 'session-not-registered'
        $result.BudgetExhausted | Should -Be $false
    }

    It 'fails loud (warns) and arms anyway when the registry is missing entirely -- never silently treats an unverifiable run as within budget' {
        $registryPath = Join-Path $TestDrive 'arm-registry-missing.json'
        $warnings = [System.Collections.Generic.List[string]]::new()
        $warningEmitter = { param($Message) $warnings.Add($Message) }

        $launchedAt = [datetime]::new(2026, 7, 23, 0, 0, 0, [System.DateTimeKind]::Utc)
        $now = $launchedAt.AddMinutes(90)

        $result = Resolve-GoalRunBudgetArmState -CurrentSessionId 'any-session' -LaunchedAt $launchedAt `
            -CeilingMinutes 60 -Now $now -RegistryPath $registryPath -WarningEmitter $warningEmitter

        $result.Armed | Should -Be $true
        $result.ArmReason | Should -Be 'registry-unverifiable: registry-missing'
        $result.BudgetExhausted | Should -Be $true
        $warnings.Count | Should -BeGreaterThan 0
    }

    It 'fails loud (warns) and arms anyway when the registry is unreadable' {
        $registryPath = Join-Path $TestDrive 'arm-registry-corrupt.json'
        Set-Content -LiteralPath $registryPath -Value 'not json at all' -Encoding utf8
        $warnings = [System.Collections.Generic.List[string]]::new()
        $warningEmitter = { param($Message) $warnings.Add($Message) }

        $launchedAt = [datetime]::new(2026, 7, 23, 0, 0, 0, [System.DateTimeKind]::Utc)
        $now = $launchedAt.AddMinutes(5)

        $result = Resolve-GoalRunBudgetArmState -CurrentSessionId 'any-session' -LaunchedAt $launchedAt `
            -CeilingMinutes 60 -Now $now -RegistryPath $registryPath -WarningEmitter $warningEmitter

        $result.Armed | Should -Be $true
        $result.ArmReason | Should -Be 'registry-unverifiable: registry-unreadable'
        $result.BudgetExhausted | Should -Be $false
        $warnings.Count | Should -BeGreaterThan 0
    }

    It 'M6 regression: a UTC Z-suffixed LaunchedAt string cast to [datetime] alongside a genuinely UTC -Now reports near-zero elapsed, not a multi-hour skew' {
        $registryPath = Join-Path $TestDrive 'arm-m6-regression.json'
        Register-GoalRunBudgetSession -SessionId 'armed-session' -Issue 874 -RegistryPath $registryPath | Out-Null

        # Same Kind-unaware bug as Test-GoalRunInflightAppearsDead
        # (goal-run-stage-core.ps1): a 'Z'-suffixed string cast to
        # [datetime] lands Kind=Local. Before the M6 fix, subtracting that
        # directly against a genuinely-Utc -Now skewed the elapsed-minutes
        # result by the local UTC offset of the running machine.
        $nowUtc = (Get-Date).ToUniversalTime()
        $launchedAtZString = $nowUtc.ToString('yyyy-MM-ddTHH:mm:ssZ')
        $launchedAtCastFromZString = [datetime]$launchedAtZString

        $result = Resolve-GoalRunBudgetArmState -CurrentSessionId 'armed-session' -LaunchedAt $launchedAtCastFromZString `
            -CeilingMinutes 60 -Now $nowUtc -RegistryPath $registryPath

        $result.Armed | Should -Be $true
        $result.BudgetExhausted | Should -Be $false
        [math]::Abs($result.ElapsedMinutes) | Should -BeLessThan 2
    }
}

# ---------------------------------------------------------------------------
# 3. Chain-boundary composite -- co-occurrence-aware wiring into step 6
# ---------------------------------------------------------------------------

Describe 'Invoke-GoalRunBudgetChainBoundaryCheck' -Tag 'unit' {

    BeforeEach {
        $script:RegistryPath = Join-Path $TestDrive "chain-boundary-$([Guid]::NewGuid().ToString('N')).json"
        Register-GoalRunBudgetSession -SessionId 'armed-session' -Issue 874 -RegistryPath $script:RegistryPath | Out-Null
        $script:LaunchedAt = [datetime]::new(2026, 7, 23, 0, 0, 0, [System.DateTimeKind]::Utc)
        $script:Exhausted = $script:LaunchedAt.AddHours(3)
    }

    It 'produces a real budget-exhausted halt when armed and past the ceiling, with no other condition true' {
        $result = Invoke-GoalRunBudgetChainBoundaryCheck -CurrentSessionId 'armed-session' -LaunchedAt $script:LaunchedAt `
            -CeilingMinutes 60 -Now $script:Exhausted -RegistryPath $script:RegistryPath

        $result.ArmState.BudgetExhausted | Should -Be $true
        $result.Precedence.HasHalt | Should -Be $true
        $result.Precedence.HaltReason | Should -Be 'budget-exhausted'
        $result.Precedence.TrueConditions | Should -Be @('budget-exhausted')
    }

    It 'lets invariant-conflict win over a real budget-exhausted condition (co-occurrence, precedence order preserved)' {
        $result = Invoke-GoalRunBudgetChainBoundaryCheck -CurrentSessionId 'armed-session' -LaunchedAt $script:LaunchedAt `
            -CeilingMinutes 60 -Now $script:Exhausted -RegistryPath $script:RegistryPath -InvariantConflict

        $result.ArmState.BudgetExhausted | Should -Be $true
        $result.Precedence.HaltReason | Should -Be 'invariant-conflict'
        $result.Precedence.TrueConditions | Should -Be @('invariant-conflict', 'budget-exhausted')
    }

    It 'lets a real budget-exhausted condition win over chain-stage-failure (co-occurrence, precedence order preserved)' {
        $result = Invoke-GoalRunBudgetChainBoundaryCheck -CurrentSessionId 'armed-session' -LaunchedAt $script:LaunchedAt `
            -CeilingMinutes 60 -Now $script:Exhausted -RegistryPath $script:RegistryPath -ChainStageFailure

        $result.Precedence.HaltReason | Should -Be 'budget-exhausted'
        $result.Precedence.TrueConditions | Should -Be @('budget-exhausted', 'chain-stage-failure')
    }

    It 'never halts on budget for a bystander session, even far past the ceiling, with no other condition true' {
        $result = Invoke-GoalRunBudgetChainBoundaryCheck -CurrentSessionId 'a-diagnostic-session-poking-around' -LaunchedAt $script:LaunchedAt `
            -CeilingMinutes 60 -Now $script:Exhausted -RegistryPath $script:RegistryPath

        $result.ArmState.Armed | Should -Be $false
        $result.Precedence.HasHalt | Should -Be $false
        $result.Precedence.HaltReason | Should -BeNullOrEmpty
    }
}

# ---------------------------------------------------------------------------
# 4. End-of-run token accounting
# ---------------------------------------------------------------------------

Describe 'Get-GoalRunSessionTokenAccounting' -Tag 'unit' {

    It 'reports accounting-unavailable when the transcript does not exist' {
        $path = Join-Path $TestDrive 'missing-transcript.jsonl'
        $result = Get-GoalRunSessionTokenAccounting -TranscriptPath $path
        $result.State | Should -Be 'accounting-unavailable'
        $result.Reason | Should -Be 'transcript-not-found'
    }

    It 'reports accounting-unavailable when the transcript is empty' {
        $path = Join-Path $TestDrive 'empty-transcript.jsonl'
        New-Item -ItemType File -Path $path -Force | Out-Null
        $result = Get-GoalRunSessionTokenAccounting -TranscriptPath $path
        $result.State | Should -Be 'accounting-unavailable'
        $result.Reason | Should -Be 'transcript-empty'
    }

    It 'sums usage across every assistant event when no terminal result event is present (Arm I interactive shape)' {
        $path = Join-Path $TestDrive 'interactive-multi-turn.jsonl'
        $lines = @(
            '{"type":"assistant","message":{"content":"turn 1","usage":{"input_tokens":10,"output_tokens":5,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}'
            '{"type":"assistant","message":{"content":"turn 2","usage":{"input_tokens":20,"output_tokens":15,"cache_creation_input_tokens":2,"cache_read_input_tokens":3}}}'
        )
        Set-Content -LiteralPath $path -Value $lines -Encoding utf8

        $result = Get-GoalRunSessionTokenAccounting -TranscriptPath $path
        $result.State | Should -Be 'accounting-present'
        $result.Provenance | Should -Be 'assistant-turn-sum'
        $result.Tokens.input | Should -Be 30
        $result.Tokens.output | Should -Be 20
        $result.Tokens.cache_creation | Should -Be 2
        $result.Tokens.cache_read | Should -Be 3
        $result.UsageCrossChecked | Should -Be $false
        $result.TotalCostUsd | Should -BeNullOrEmpty
    }

    It 'trusts a healthy non-zero usage object on a terminal result event' {
        $path = Join-Path $TestDrive 'healthy-result.jsonl'
        $line = '{"type":"result","subtype":"success","total_cost_usd":0.0335877,"usage":{"input_tokens":34,"output_tokens":4342,"cache_creation_input_tokens":26718,"cache_read_input_tokens":840600},"modelUsage":{"claude-sonnet-5":{"inputTokens":34,"outputTokens":4342,"cacheReadInputTokens":840600,"cacheCreationInputTokens":26718,"costUSD":0.0335877}}}'
        Set-Content -LiteralPath $path -Value $line -Encoding utf8

        $result = Get-GoalRunSessionTokenAccounting -TranscriptPath $path
        $result.State | Should -Be 'accounting-present'
        $result.Provenance | Should -Be 'result-event-usage'
        $result.Tokens.output | Should -Be 4342
        $result.UsageWasAllZero | Should -Be $false
        $result.TotalCostUsd | Should -Be 0.0335877
    }

    It 'does NOT report zero when usage is all-zero but modelUsage/total_cost_usd are non-zero (the #873 silent-zero defect class, leg c fixture)' {
        $path = Join-Path $TestDrive 'silent-zero-result.jsonl'
        $line = '{"type":"result","subtype":"error_max_budget_usd","is_error":true,"total_cost_usd":0.0335877,"usage":{"input_tokens":0,"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"iterations":[]},"modelUsage":{"claude-sonnet-4-6":{"inputTokens":3,"outputTokens":648,"cacheReadInputTokens":18779,"cacheCreationInputTokens":4860,"costUSD":0.0335877}}}'
        Set-Content -LiteralPath $path -Value $line -Encoding utf8

        $result = Get-GoalRunSessionTokenAccounting -TranscriptPath $path
        $result.State | Should -Be 'accounting-present'
        $result.Provenance | Should -Be 'result-event-modelusage-crosscheck'
        $result.UsageWasAllZero | Should -Be $true
        $result.UsageCrossChecked | Should -Be $true
        $result.Tokens.output | Should -Be 648
        $result.Tokens.output | Should -Not -Be 0
        $result.TotalCostUsd | Should -Be 0.0335877
    }

    It 'M20: redacts a secret-shaped modelUsage key before returning it in ModelUsageKeys' {
        $path = Join-Path $TestDrive 'secret-shaped-model-key-result.jsonl'
        # modelUsage keys are free-form transcript-derived strings read
        # straight off the terminal result event, with no allow-list
        # filtering upstream (unlike goal_status.condition/reason) -- a
        # secret-shaped key must still be redacted before it is ever
        # returned.
        $line = '{"type":"result","subtype":"success","total_cost_usd":0.01,"usage":{"input_tokens":0,"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0},"modelUsage":{"api_key: LiveSecretValue987654":{"inputTokens":5,"outputTokens":5,"cacheReadInputTokens":0,"cacheCreationInputTokens":0}}}'
        Set-Content -LiteralPath $path -Value $line -Encoding utf8

        $result = Get-GoalRunSessionTokenAccounting -TranscriptPath $path
        ($result.ModelUsageKeys -join '|') | Should -Not -Match 'LiveSecretValue987654'
        ($result.ModelUsageKeys -join '|') | Should -Match '\[REDACTED:kv-secret-assignment\]'
    }

    It 'sums ALL modelUsage keys, including an unrequested secondary model, dropping neither' {
        $path = Join-Path $TestDrive 'multi-model-result.jsonl'
        $line = '{"type":"result","subtype":"success","total_cost_usd":0.5159808,"usage":{"input_tokens":0,"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0},"modelUsage":{"claude-sonnet-5":{"inputTokens":100,"outputTokens":200,"cacheReadInputTokens":10,"cacheCreationInputTokens":5},"claude-haiku-4-5-20251001":{"inputTokens":7,"outputTokens":13,"cacheReadInputTokens":1,"cacheCreationInputTokens":0}}}'
        Set-Content -LiteralPath $path -Value $line -Encoding utf8

        $result = Get-GoalRunSessionTokenAccounting -TranscriptPath $path
        $result.Provenance | Should -Be 'result-event-modelusage-crosscheck'
        $result.ModelUsageKeys | Should -Contain 'claude-sonnet-5'
        $result.ModelUsageKeys | Should -Contain 'claude-haiku-4-5-20251001'
        $result.Tokens.input | Should -Be 107
        $result.Tokens.output | Should -Be 213
        $result.Tokens.cache_read | Should -Be 11
        $result.Tokens.cache_creation | Should -Be 5
    }

    It 'reports a genuine zero when usage, modelUsage, and total_cost_usd all agree on zero' {
        $path = Join-Path $TestDrive 'genuine-zero-result.jsonl'
        $line = '{"type":"result","subtype":"success","total_cost_usd":0,"usage":{"input_tokens":0,"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0},"modelUsage":{"claude-sonnet-5":{"inputTokens":0,"outputTokens":0,"cacheReadInputTokens":0,"cacheCreationInputTokens":0}}}'
        Set-Content -LiteralPath $path -Value $line -Encoding utf8

        $result = Get-GoalRunSessionTokenAccounting -TranscriptPath $path
        $result.Provenance | Should -Be 'result-event-usage'
        $result.UsageWasAllZero | Should -Be $true
        $result.CrossCheckReason | Should -BeNullOrEmpty
        $result.Tokens.input | Should -Be 0
    }

    It 'does not throw and treats total_cost_usd as unavailable when it arrives as a JSON object instead of a number' {
        $path = Join-Path $TestDrive 'weird-cost-shape-result.jsonl'
        $line = '{"type":"result","subtype":"success","total_cost_usd":{"nested":"object"},"usage":{"input_tokens":5,"output_tokens":5,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}'
        Set-Content -LiteralPath $path -Value $line -Encoding utf8

        { Get-GoalRunSessionTokenAccounting -TranscriptPath $path } | Should -Not -Throw
        $result = Get-GoalRunSessionTokenAccounting -TranscriptPath $path
        $result.TotalCostUsd | Should -BeNullOrEmpty
    }

    It 'tolerates a malformed or partial mid-write tail line without throwing' {
        $path = Join-Path $TestDrive 'partial-tail-result.jsonl'
        $goodLine = '{"type":"assistant","message":{"content":"hi","usage":{"input_tokens":50,"output_tokens":10,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}'
        $partialLine = '{"type":"assistant","message":{"content":"still writ'
        Set-Content -LiteralPath $path -Value @($goodLine, $partialLine) -Encoding utf8

        { Get-GoalRunSessionTokenAccounting -TranscriptPath $path } | Should -Not -Throw
        $result = Get-GoalRunSessionTokenAccounting -TranscriptPath $path
        $result.Tokens.input | Should -Be 50
    }
}

# ---------------------------------------------------------------------------
# 5. Chain-stage-boundary composite (M4/M5/M9, M8 reachability)
# ---------------------------------------------------------------------------

Describe 'Invoke-GoalRunChainStageBoundaryHousekeeping' -Tag 'unit' {

    BeforeEach {
        $script:HkWorktreePath = Join-Path $TestDrive "housekeeping-$([Guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path $script:HkWorktreePath -Force | Out-Null
        New-GoalRunActiveState -WorktreePath $script:HkWorktreePath -Ceilings @{} -Baseline @{} -Arm 'in-session' `
            -ExecutorSessionId 'armed-session' -ContractHash ('d' * 64) | Out-Null

        $script:HkRegistryPath = Join-Path $TestDrive "housekeeping-registry-$([Guid]::NewGuid().ToString('N')).json"
        Register-GoalRunBudgetSession -SessionId 'armed-session' -Issue 874 -RegistryPath $script:HkRegistryPath | Out-Null
        $script:HkLaunchedAt = [datetime]::new(2026, 7, 23, 0, 0, 0, [System.DateTimeKind]::Utc)
    }

    It 'M8 reachability: one call genuinely refreshes the heartbeat on disk, writes a readable run-log checkpoint, and resolves the wall-clock arm state -- proving the seam actually composes, not just each side in isolation' {
        $before = Get-GoalRunActiveState -WorktreePath $script:HkWorktreePath
        Start-Sleep -Milliseconds 50

        $result = Invoke-GoalRunChainStageBoundaryHousekeeping -WorktreePath $script:HkWorktreePath -Issue 874 `
            -CurrentSessionId 'armed-session' -LaunchedAt $script:HkLaunchedAt -CeilingMinutes 60 `
            -CommitSha 'abc1234' -CheckpointSummary 'stage 1: entering' -RegistryPath $script:HkRegistryPath `
            -Now $script:HkLaunchedAt.AddMinutes(10) -RepoRoot $script:RepoRoot

        # 1. Heartbeat genuinely refreshed on disk, not merely returned.
        $after = Get-GoalRunActiveState -WorktreePath $script:HkWorktreePath
        ([datetime]$after.heartbeat_at) | Should -BeGreaterThan ([datetime]$before.heartbeat_at)

        # 2. Run-log checkpoint genuinely written and readable back through
        # the actual reader Resolve-GoalRunResumeStage consumes.
        (Test-GoalRunLogHasCheckpoint -WorktreePath $script:HkWorktreePath) | Should -Be $true

        # 3. Budget-arm state genuinely resolved (armed + not yet exhausted
        # at 10 of 60 minutes).
        $result.ArmState.Armed | Should -Be $true
        $result.ArmState.BudgetExhausted | Should -Be $false
        $result.Precedence.HasHalt | Should -Be $false
        $result.HeartbeatError | Should -BeNullOrEmpty
    }

    It 'wires -BudgetExhausted from the real arm-state result into the winning halt reason once the ceiling has passed' {
        $result = Invoke-GoalRunChainStageBoundaryHousekeeping -WorktreePath $script:HkWorktreePath -Issue 874 `
            -CurrentSessionId 'armed-session' -LaunchedAt $script:HkLaunchedAt -CeilingMinutes 60 `
            -CommitSha 'abc1234' -CheckpointSummary 'stage 1: entering' -RegistryPath $script:HkRegistryPath `
            -Now $script:HkLaunchedAt.AddHours(3) -RepoRoot $script:RepoRoot

        $result.Precedence.HasHalt | Should -Be $true
        $result.Precedence.HaltReason | Should -Be 'budget-exhausted'
    }

    It 'passes a co-occurring -ChainStageFailure through correctly (budget-exhausted still wins per the total precedence order)' {
        $result = Invoke-GoalRunChainStageBoundaryHousekeeping -WorktreePath $script:HkWorktreePath -Issue 874 `
            -CurrentSessionId 'armed-session' -LaunchedAt $script:HkLaunchedAt -CeilingMinutes 60 `
            -CommitSha 'abc1234' -CheckpointSummary 'stage 1: entering' -RegistryPath $script:HkRegistryPath `
            -Now $script:HkLaunchedAt.AddHours(3) -RepoRoot $script:RepoRoot -ChainStageFailure

        $result.Precedence.HaltReason | Should -Be 'budget-exhausted'
        $result.Precedence.TrueConditions | Should -Be @('budget-exhausted', 'chain-stage-failure')
    }

    It 'catches a heartbeat-update failure, surfaces it on HeartbeatError, and still resolves the budget-arm state (housekeeping failure is never fatal to the chain-stage transition)' {
        $missingWorktree = Join-Path $TestDrive "missing-worktree-$([Guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path $missingWorktree -Force | Out-Null

        $result = Invoke-GoalRunChainStageBoundaryHousekeeping -WorktreePath $missingWorktree -Issue 874 `
            -CurrentSessionId 'armed-session' -LaunchedAt $script:HkLaunchedAt -CeilingMinutes 60 `
            -CommitSha 'abc1234' -CheckpointSummary 'stage 1: entering' -RegistryPath $script:HkRegistryPath `
            -Now $script:HkLaunchedAt.AddMinutes(5) -RepoRoot $script:RepoRoot -WarningAction SilentlyContinue

        $result.HeartbeatError | Should -Not -BeNullOrEmpty
        $result.ArmState | Should -Not -BeNullOrEmpty
        $result.ArmState.Armed | Should -Be $true
    }
}
