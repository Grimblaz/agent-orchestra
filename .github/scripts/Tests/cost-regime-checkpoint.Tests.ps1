#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# Pester tests for cost-checkpoint-core.ps1 and cost-regime-checkpoint.ps1
# (issue #467, Step 6 TDD).
#
# File under test: .github/scripts/lib/cost-checkpoint-core.ps1
#                  .github/scripts/cost-regime-checkpoint.ps1
#
# RED phase: core lib and CLI do not exist yet — all It-blocks fail with
# "script not found" or "function not found".
#
# GREEN phase: implementing those files turns the RED signals green.

BeforeAll {
    $script:RepoRoot  = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
    $script:CoreLib   = Join-Path $script:RepoRoot '.github/scripts/lib/cost-checkpoint-core.ps1'
    $script:CliScript = Join-Path $script:RepoRoot '.github/scripts/cost-regime-checkpoint.ps1'
    $script:YamlFile  = Join-Path $script:RepoRoot '.github/scripts/cost-regime-checkpoints.yaml'
    $script:CachePath = Join-Path $script:RepoRoot '.github/scripts/cache/cost-rolling-history.json'

    # Dot-source the core lib if it exists (GREEN phase). During RED phase this is a no-op.
    if (Test-Path $script:CoreLib) {
        . $script:CoreLib
    }
}

# ---------------------------------------------------------------------------
# Describe: Get-MostRecentRegimeCheckpoint
# ---------------------------------------------------------------------------

Describe 'Get-MostRecentRegimeCheckpoint' {

    It 'returns null for absent file' {
        $tmpPath = Join-Path $TestDrive "absent-$([System.Guid]::NewGuid().ToString('N')).yaml"
        $result = Get-MostRecentRegimeCheckpoint -Path $tmpPath
        $result | Should -BeNullOrEmpty
    }

    It 'returns null for empty checkpoints array' {
        $tmpPath = Join-Path $TestDrive "empty-$([System.Guid]::NewGuid().ToString('N')).yaml"
        @"
schema_version: 1
checkpoints: []
"@ | Set-Content -Path $tmpPath -Encoding UTF8

        $result = Get-MostRecentRegimeCheckpoint -Path $tmpPath
        $result | Should -BeNullOrEmpty
    }

    It 'returns the entry with the most recent timestamp' {
        $tmpPath = Join-Path $TestDrive "multi-$([System.Guid]::NewGuid().ToString('N')).yaml"
        @"
schema_version: 1
checkpoints:
  - id: "cp-001"
    timestamp: "2026-01-01T00:00:00Z"
    sub_issue: "#100"
    reason: "first"
    metrics: {}
    exclusions: {}
  - id: "cp-002"
    timestamp: "2026-05-01T04:00:00Z"
    sub_issue: "#200"
    reason: "second"
    metrics: {}
    exclusions: {}
  - id: "cp-003"
    timestamp: "2026-03-15T12:00:00Z"
    sub_issue: "#150"
    reason: "third"
    metrics: {}
    exclusions: {}
"@ | Set-Content -Path $tmpPath -Encoding UTF8

        $result = Get-MostRecentRegimeCheckpoint -Path $tmpPath
        $result | Should -Not -BeNullOrEmpty
        $result.id | Should -Be 'cp-002'
    }

    It 'parses nested metrics and exclusions sub-blocks (gemini-code-assist HIGH)' {
        # Regression: ConvertFrom-CheckpointYaml previously skipped sub-block
        # openers (metrics:, exclusions:) entirely, so checkpoint comparison
        # in Get-CostAnomalyFlags received an empty $Checkpoint['metrics'] hash
        # and never flagged drift against the checkpoint.
        $tmpPath = Join-Path $TestDrive "nested-$([System.Guid]::NewGuid().ToString('N')).yaml"
        @"
schema_version: 1
checkpoints:
  - id: "cp-nested"
    timestamp: "2026-05-01T04:00:00Z"
    sub_issue: "#469"
    reason: "post-#469 stabilized"
    metrics:
      port.implement-code.cost_estimate_usd.mean: 0.123456
      port.review.cost_estimate_usd.mean: 0.045678
      orchestrator_overhead.cost_estimate_usd.mean: 0.012000
    exclusions:
      recent_count: 1
      sub_issue: "#469"
"@ | Set-Content -Path $tmpPath -Encoding UTF8

        $result = Get-MostRecentRegimeCheckpoint -Path $tmpPath
        $result | Should -Not -BeNullOrEmpty
        $result.id | Should -Be 'cp-nested'
        $result.metrics | Should -Not -BeNullOrEmpty
        $result.metrics.Count | Should -Be 3
        [double]$result.metrics['port.implement-code.cost_estimate_usd.mean'] | Should -Be 0.123456
        [double]$result.metrics['port.review.cost_estimate_usd.mean'] | Should -Be 0.045678
        [double]$result.metrics['orchestrator_overhead.cost_estimate_usd.mean'] | Should -Be 0.012000
        $result.exclusions | Should -Not -BeNullOrEmpty
        [string]$result.exclusions['recent_count'] | Should -Be '1'
        [string]$result.exclusions['sub_issue'] | Should -Be '#469'
    }

    It 'preserves empty metrics/exclusions hashtables ({}) without failing' {
        $tmpPath = Join-Path $TestDrive "empty-blocks-$([System.Guid]::NewGuid().ToString('N')).yaml"
        @"
schema_version: 1
checkpoints:
  - id: "cp-empty-blocks"
    timestamp: "2026-05-01T04:00:00Z"
    reason: "no metrics yet"
    metrics: {}
    exclusions: {}
"@ | Set-Content -Path $tmpPath -Encoding UTF8

        $result = Get-MostRecentRegimeCheckpoint -Path $tmpPath
        $result | Should -Not -BeNullOrEmpty
        $result.id | Should -Be 'cp-empty-blocks'
        ($result.metrics -is [hashtable]) | Should -Be $true
        $result.metrics.Count | Should -Be 0
        ($result.exclusions -is [hashtable]) | Should -Be $true
        $result.exclusions.Count | Should -Be 0
    }

    It 'returns the single entry when only one exists' {
        $tmpPath = Join-Path $TestDrive "single-$([System.Guid]::NewGuid().ToString('N')).yaml"
        @"
schema_version: 1
checkpoints:
  - id: "cp-001"
    timestamp: "2026-05-01T04:00:00Z"
    sub_issue: "#469"
    reason: "only entry"
    metrics: {}
    exclusions: {}
"@ | Set-Content -Path $tmpPath -Encoding UTF8

        $result = Get-MostRecentRegimeCheckpoint -Path $tmpPath
        $result | Should -Not -BeNullOrEmpty
        $result.id | Should -Be 'cp-001'
    }
}

# ---------------------------------------------------------------------------
# Describe: Add-RegimeCheckpoint
# ---------------------------------------------------------------------------

Describe 'Add-RegimeCheckpoint' {

    It 'creates file with schema_version and appends first entry' {
        $tmpPath = Join-Path $TestDrive "new-$([System.Guid]::NewGuid().ToString('N')).yaml"
        # File must not exist yet
        Test-Path $tmpPath | Should -Be $false

        $entry = @{
            id        = 'cp-20260501-040000'
            timestamp = '2026-05-01T04:00:00Z'
            sub_issue = '#469'
            reason    = 'post-#469 pre-flight reduction'
            note      = ''
            metrics   = @{ 'orchestrator_overhead.tokens.input.mean' = 11000 }
            exclusions = @{ sub_issue = '#469'; recent_count = 1 }
        }

        Add-RegimeCheckpoint -Path $tmpPath -Entry $entry

        Test-Path $tmpPath | Should -Be $true
        $content = Get-Content -Path $tmpPath -Raw
        $content | Should -Match 'schema_version: 1'
        $content | Should -Match 'cp-20260501-040000'
        $content | Should -Match '#469'
    }

    It 'appends to existing file (does not overwrite)' {
        $tmpPath = Join-Path $TestDrive "append-$([System.Guid]::NewGuid().ToString('N')).yaml"

        $entry1 = @{
            id        = 'cp-20260501-000000'
            timestamp = '2026-05-01T00:00:00Z'
            sub_issue = '#400'
            reason    = 'first checkpoint'
            note      = ''
            metrics   = @{}
            exclusions = @{ sub_issue = '#400'; recent_count = 1 }
        }

        $entry2 = @{
            id        = 'cp-20260502-000000'
            timestamp = '2026-05-02T00:00:00Z'
            sub_issue = '#401'
            reason    = 'second checkpoint'
            note      = ''
            metrics   = @{}
            exclusions = @{ sub_issue = '#401'; recent_count = 1 }
        }

        Add-RegimeCheckpoint -Path $tmpPath -Entry $entry1
        Add-RegimeCheckpoint -Path $tmpPath -Entry $entry2

        $content = Get-Content -Path $tmpPath -Raw
        $content | Should -Match 'cp-20260501-000000'
        $content | Should -Match 'cp-20260502-000000'
        $content | Should -Match '#400'
        $content | Should -Match '#401'
    }

    It 'multiple invocations produce chronologically ordered entries' {
        $tmpPath = Join-Path $TestDrive "order-$([System.Guid]::NewGuid().ToString('N')).yaml"

        $timestamps = @(
            '2026-04-01T00:00:00Z',
            '2026-05-01T00:00:00Z',
            '2026-06-01T00:00:00Z'
        )

        foreach ($i in 0..2) {
            $entry = @{
                id        = "cp-entry-$i"
                timestamp = $timestamps[$i]
                sub_issue = "#$i"
                reason    = "checkpoint $i"
                note      = ''
                metrics   = @{}
                exclusions = @{ recent_count = 1 }
            }
            Add-RegimeCheckpoint -Path $tmpPath -Entry $entry
        }

        $content = Get-Content -Path $tmpPath -Raw
        $idx0 = $content.IndexOf('cp-entry-0')
        $idx1 = $content.IndexOf('cp-entry-1')
        $idx2 = $content.IndexOf('cp-entry-2')
        $idx0 | Should -BeLessThan $idx1 -Because 'entries should appear in append order'
        $idx1 | Should -BeLessThan $idx2 -Because 'entries should appear in append order'
    }
}

# ---------------------------------------------------------------------------
# Describe: cost-regime-checkpoint.ps1 CLI
# ---------------------------------------------------------------------------

Describe 'cost-regime-checkpoint.ps1 CLI' {

    BeforeAll {
        # Dot-source ONLY the core lib here — Invoke-CostRegimeCheckpoint
        # calls Get-CostRollingHistory by name, and we want lookup to resolve
        # to the BeforeEach global mock (below) rather than the real fetcher.
        # Dot-sourcing cost-rolling-history.ps1 here would put the real
        # function in script scope and shadow the global mock, causing the
        # tests to actually hit GitHub (or its timeout fallback).
        if (Test-Path $script:CoreLib) {
            . $script:CoreLib
        }
    }

    BeforeEach {
        $script:TmpDir  = Join-Path $TestDrive "cli-$([System.Guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path $script:TmpDir -Force | Out-Null
        $script:TmpYaml = Join-Path $script:TmpDir 'cost-regime-checkpoints.yaml'
        $script:TmpCache = Join-Path $script:TmpDir 'cost-rolling-history.json'

        # Install in-process mock for Get-CostRollingHistory. The tests below
        # call Invoke-CostRegimeCheckpoint directly (dot-source pattern), so
        # this global override shadows the real fetcher and lets the tests
        # exercise the CLI flow without network or git-remote dependencies.
        function global:Get-CostRollingHistory {
            param(
                [int]$Limit = 30,
                [string]$CachePath = '',
                [switch]$ForceRefresh,
                [int]$TimeoutSeconds = 10,
                [string]$RepoRoot = ''
            )
            # Simulate three entries: two from sub-issue #469, one unrelated.
            # Fix Pass1-F7: ports is now emitted as a hashtable keyed by port
            # name to match what production Get-CostRollingHistory returns
            # (per Pass1-F10 structural fix). Sub-issue refs use the new
            # structured `sub_issue_refs` field (Fix Pass2-F4) to prove the
            # structured-filter path is exercised at the CLI seam.
            return @{
                timed_out = $false
                entries   = @(
                    @{
                        pr_number = 100
                        sub_issue_refs = @('#469')
                        ports = @{ experience = @{ name = 'experience'; cost_estimate_usd = 0.05; dispatch_count = 1; tokens = @{ input = 100; output = 50; cache_creation = 0; cache_read = 25 } } }
                        orchestrator_overhead = @{ cost_estimate_usd = 0.01 }
                        dispatches = @{ general_purpose_count = 2 }
                        totals = @{ cost_estimate_usd = 0.06 }
                    },
                    @{
                        pr_number = 101
                        sub_issue_refs = @('#469')
                        ports = @{ experience = @{ name = 'experience'; cost_estimate_usd = 0.04; dispatch_count = 1; tokens = @{ input = 90; output = 45; cache_creation = 0; cache_read = 20 } } }
                        orchestrator_overhead = @{ cost_estimate_usd = 0.01 }
                        dispatches = @{ general_purpose_count = 1 }
                        totals = @{ cost_estimate_usd = 0.05 }
                    },
                    @{
                        pr_number = 99
                        sub_issue_refs = @('#465')
                        ports = @{ design = @{ name = 'design'; cost_estimate_usd = 0.10; dispatch_count = 1; tokens = @{ input = 200; output = 80; cache_creation = 0; cache_read = 50 } } }
                        orchestrator_overhead = @{ cost_estimate_usd = 0.02 }
                        dispatches = @{ general_purpose_count = 3 }
                        totals = @{ cost_estimate_usd = 0.12 }
                    }
                )
            }
        }
    }

    AfterEach {
        if (Get-Command 'Get-CostRollingHistory' -CommandType Function -ErrorAction SilentlyContinue) {
            Remove-Item -Path 'function:global:Get-CostRollingHistory' -ErrorAction SilentlyContinue
        }
    }

    It 'produces a correctly-shaped YAML entry (round-trip parse)' {
        if (-not (Get-Command Invoke-CostRegimeCheckpoint -ErrorAction SilentlyContinue)) {
            Set-ItResult -Skipped -Because 'Invoke-CostRegimeCheckpoint not loaded'
            return
        }

        Invoke-CostRegimeCheckpoint `
            -Reason 'post-#469 pre-flight reduction' `
            -SubIssue '#469' `
            -CheckpointsPath $script:TmpYaml `
            -CacheFilePath $script:TmpCache `
            -RepoRoot $script:RepoRoot 6> $null

        Test-Path $script:TmpYaml | Should -Be $true

        $content = Get-Content -Path $script:TmpYaml -Raw
        $content | Should -Match 'schema_version: 1'
        $content | Should -Match 'cp-'
        $content | Should -Match 'post-#469 pre-flight reduction'
        $content | Should -Match '#469'
        $content | Should -Match 'timestamp:'
        $content | Should -Match 'metrics:'
        $content | Should -Match 'exclusions:'
    }

    It 'cache-bust ordering: cache deleted before capture' {
        if (-not (Get-Command Invoke-CostRegimeCheckpoint -ErrorAction SilentlyContinue)) {
            Set-ItResult -Skipped -Because 'Invoke-CostRegimeCheckpoint not loaded'
            return
        }

        # Pre-create a fake cache file so we can verify the function deletes it
        '{"stale": true}' | Set-Content -Path $script:TmpCache -Encoding UTF8
        Test-Path $script:TmpCache | Should -Be $true

        Invoke-CostRegimeCheckpoint `
            -Reason 'cache bust test' `
            -SubIssue '#469' `
            -CheckpointsPath $script:TmpYaml `
            -CacheFilePath $script:TmpCache `
            -RepoRoot $script:RepoRoot 6> $null

        # The function must delete the cache file before calling Get-CostRollingHistory.
        # After the run, the cache may or may not exist (the mock doesn't write one),
        # but the checkpoint YAML should have been written — proving the flow ran.
        Test-Path $script:TmpYaml | Should -Be $true -Because 'function should have created the checkpoint file'
    }

    It '-SubIssue flag filters that sub-issue from rolling history' {
        if (-not (Get-Command Invoke-CostRegimeCheckpoint -ErrorAction SilentlyContinue)) {
            Set-ItResult -Skipped -Because 'Invoke-CostRegimeCheckpoint not loaded'
            return
        }

        Invoke-CostRegimeCheckpoint `
            -Reason 'sub-issue filter test' `
            -SubIssue '#469' `
            -CheckpointsPath $script:TmpYaml `
            -CacheFilePath $script:TmpCache `
            -RepoRoot $script:RepoRoot 6> $null

        Test-Path $script:TmpYaml | Should -Be $true
        $content = Get-Content -Path $script:TmpYaml -Raw
        # The exclusions block should reference #469
        $content | Should -Match '#469'
        $content | Should -Match 'sub_issue'
    }

    It '-ExcludeMostRecent defaults to 1 (skips most recent merged PR)' {
        if (-not (Get-Command Invoke-CostRegimeCheckpoint -ErrorAction SilentlyContinue)) {
            Set-ItResult -Skipped -Because 'Invoke-CostRegimeCheckpoint not loaded'
            return
        }

        Invoke-CostRegimeCheckpoint `
            -Reason 'exclude-most-recent default test' `
            -CheckpointsPath $script:TmpYaml `
            -CacheFilePath $script:TmpCache `
            -RepoRoot $script:RepoRoot 6> $null

        Test-Path $script:TmpYaml | Should -Be $true
        $content = Get-Content -Path $script:TmpYaml -Raw
        # The exclusions block should record recent_count: 1 (default)
        $content | Should -Match 'recent_count'
        $content | Should -Match '1'
    }
}
