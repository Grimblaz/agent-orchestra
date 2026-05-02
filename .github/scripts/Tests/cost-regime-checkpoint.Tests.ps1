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
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
    $script:CoreLib = Join-Path $script:RepoRoot '.github/scripts/lib/cost-checkpoint-core.ps1'
    $script:CliScript = Join-Path $script:RepoRoot '.github/scripts/cost-regime-checkpoint.ps1'
    $script:YamlFile = Join-Path $script:RepoRoot '.github/scripts/cost-regime-checkpoints.yaml'
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
            id         = 'cp-20260501-040000'
            timestamp  = '2026-05-01T04:00:00Z'
            sub_issue  = '#469'
            reason     = 'post-#469 pre-flight reduction'
            note       = ''
            metrics    = @{ 'orchestrator_overhead.tokens.input.mean' = 11000 }
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
            id         = 'cp-20260501-000000'
            timestamp  = '2026-05-01T00:00:00Z'
            sub_issue  = '#400'
            reason     = 'first checkpoint'
            note       = ''
            metrics    = @{}
            exclusions = @{ sub_issue = '#400'; recent_count = 1 }
        }

        $entry2 = @{
            id         = 'cp-20260502-000000'
            timestamp  = '2026-05-02T00:00:00Z'
            sub_issue  = '#401'
            reason     = 'second checkpoint'
            note       = ''
            metrics    = @{}
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
                id         = "cp-entry-$i"
                timestamp  = $timestamps[$i]
                sub_issue  = "#$i"
                reason     = "checkpoint $i"
                note       = ''
                metrics    = @{}
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
        $script:TmpDir = Join-Path $TestDrive "cli-$([System.Guid]::NewGuid().ToString('N'))"
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
            # AC2 (issue #492 Step 3): Capture whether the cache file existed at
            # the moment this mock is invoked. Invoke-CostRegimeCheckpoint must
            # delete the cache BEFORE calling Get-CostRollingHistory (M5 Step 1
            # then Step 2). If that ordering is correct, the file is gone by the
            # time we reach here and $global:cacheExistedAtFetch = $false.
            $global:cacheExistedAtFetch = Test-Path -LiteralPath $CachePath

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
                        pr_number             = 100
                        sub_issue_refs        = @('#469')
                        ports                 = @{ experience = @{ name = 'experience'; cost_estimate_usd = 0.05; dispatch_count = 1; tokens = @{ input = 100; output = 50; cache_creation = 0; cache_read = 25 } } }
                        orchestrator_overhead = @{ cost_estimate_usd = 0.01 }
                        dispatches            = @{ general_purpose_count = 2 }
                        totals                = @{ cost_estimate_usd = 0.06 }
                    },
                    @{
                        pr_number             = 101
                        sub_issue_refs        = @('#469')
                        ports                 = @{ experience = @{ name = 'experience'; cost_estimate_usd = 0.04; dispatch_count = 1; tokens = @{ input = 90; output = 45; cache_creation = 0; cache_read = 20 } } }
                        orchestrator_overhead = @{ cost_estimate_usd = 0.01 }
                        dispatches            = @{ general_purpose_count = 1 }
                        totals                = @{ cost_estimate_usd = 0.05 }
                    },
                    @{
                        pr_number             = 99
                        sub_issue_refs        = @('#465')
                        ports                 = @{ design = @{ name = 'design'; cost_estimate_usd = 0.10; dispatch_count = 1; tokens = @{ input = 200; output = 80; cache_creation = 0; cache_read = 50 } } }
                        orchestrator_overhead = @{ cost_estimate_usd = 0.02 }
                        dispatches            = @{ general_purpose_count = 3 }
                        totals                = @{ cost_estimate_usd = 0.12 }
                    }
                )
            }
        }
    }

    AfterEach {
        if (Get-Command 'Get-CostRollingHistory' -CommandType Function -ErrorAction SilentlyContinue) {
            Remove-Item -Path 'function:global:Get-CostRollingHistory' -ErrorAction SilentlyContinue
        }
        # Clean up AC2 observation variable so it doesn't leak between tests.
        Remove-Variable -Name cacheExistedAtFetch -Scope Global -ErrorAction SilentlyContinue
    }

    It 'produces a correctly-shaped YAML entry via the CLI (smoke check)' {
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

        # AC2 (issue #492): The function must delete the cache file BEFORE calling
        # Get-CostRollingHistory. The mock records whether the cache existed at
        # call time; $global:cacheExistedAtFetch must be $false to prove ordering.
        $global:cacheExistedAtFetch | Should -Be $false -Because 'cache must be deleted before Get-CostRollingHistory is invoked'
        # Checkpoint YAML should also have been written (flow completed).
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

# ---------------------------------------------------------------------------
# Describe: Round-trip — Add-RegimeCheckpoint <-> Get-MostRecentRegimeCheckpoint
# (AC1 — issue #492 Step 1 RED)
#
# These tests write entries via Add-RegimeCheckpoint and read them back via
# Get-MostRecentRegimeCheckpoint, asserting exact field-level round-trip
# fidelity. Two cases:
#   (a) Populated — edge values including regex-metachar strings ($1, $&, $$)
#       that expose the bootstrap -replace substitution bug (issue #492 Step 2).
#   (b) Empty-block — metrics = @{} / exclusions = @{} round-trip.
#
# RED phase: the populated case fails because Add-RegimeCheckpoint's bootstrap
# path ($existing -replace '...', $replacement) silently mutates $1/$& in the
# replacement string. GREEN after Step 2 escapes $ in $replacement.
# ---------------------------------------------------------------------------

Describe 'Round-trip: Add-RegimeCheckpoint and Get-MostRecentRegimeCheckpoint' {

    It 'round-trip preserves all fields including regex-metachar values (populated case)' {
        if (-not (Get-Command Add-RegimeCheckpoint -ErrorAction SilentlyContinue) -or
            -not (Get-Command Get-MostRecentRegimeCheckpoint -ErrorAction SilentlyContinue)) {
            Set-ItResult -Skipped -Because 'core functions not loaded'
            return
        }

        $tmpPath = Join-Path $TestDrive "rt-populated-$([System.Guid]::NewGuid().ToString('N')).yaml"

        # --- Bootstrap call (entry 1) ---
        # reason contains $1, $&, $$ — values that PowerShell's -replace operator
        # treats as substitution metacharacters and will silently corrupt if not
        # pre-escaped in the replacement string.
        $entry1 = @{
            id         = 'cp-rt-001'
            timestamp  = '2026-01-01T10:00:00Z'
            sub_issue  = '#492'
            reason     = 'cost $1 savings: $& via regex $$double'
            note       = ''
            metrics    = @{ cost_usd = '0.05'; token_count = '1000' }
            exclusions = @{ sub_issue = '#469'; recent_count = '1' }
        }
        Add-RegimeCheckpoint -Path $tmpPath -Entry $entry1

        # After bootstrap: most-recent must be entry1 with exact field values.
        $after1 = Get-MostRecentRegimeCheckpoint -Path $tmpPath
        $after1 | Should -Not -BeNullOrEmpty
        [string]$after1['id']        | Should -Be 'cp-rt-001'
        [string]$after1['timestamp'] | Should -Be '2026-01-01T10:00:00Z'
        [string]$after1['sub_issue'] | Should -Be '#492'
        # Primary AC1 assertion: reason survives the bootstrap -replace boundary unmangled.
        [string]$after1['reason']    | Should -Be 'cost $1 savings: $& via regex $$double'
        # note not written when empty — key absent or null
        [string]$after1['note']      | Should -BeNullOrEmpty
        # metrics: per-key assertions (avoids hashtable ToString() false-positive)
        $after1['metrics']                        | Should -BeOfType [hashtable]
        $after1['metrics'].Keys.Count             | Should -Be 2
        [string]$after1['metrics']['cost_usd']    | Should -Be '0.05'
        [string]$after1['metrics']['token_count'] | Should -Be '1000'
        # exclusions: per-key assertions
        $after1['exclusions']                          | Should -BeOfType [hashtable]
        $after1['exclusions'].Keys.Count               | Should -Be 2
        [string]$after1['exclusions']['sub_issue']     | Should -Be '#469'
        [string]$after1['exclusions']['recent_count']  | Should -Be '1'

        # --- Append call (entry 2) ---
        # newer timestamp; exercises the double-quote escape round-trip ("..." → \"...\" → "...").
        # Backslash round-trip is covered by the dedicated 'single backslashes' test below.
        $entry2 = @{
            id         = 'cp-rt-002'
            timestamp  = '2026-02-01T10:00:00Z'
            sub_issue  = '#492'
            reason     = 'append with "quoted text" in the reason'
            note       = 'test note value'
            metrics    = @{ delta_usd = '0.10' }
            exclusions = @{ recent_count = '2' }
        }
        Add-RegimeCheckpoint -Path $tmpPath -Entry $entry2

        # After append: most-recent must now be entry2 (newer timestamp).
        $after2 = Get-MostRecentRegimeCheckpoint -Path $tmpPath
        $after2 | Should -Not -BeNullOrEmpty
        [string]$after2['id']        | Should -Be 'cp-rt-002'
        [string]$after2['timestamp'] | Should -Be '2026-02-01T10:00:00Z'
        [string]$after2['sub_issue'] | Should -Be '#492'
        [string]$after2['reason']    | Should -Be 'append with "quoted text" in the reason'
        [string]$after2['note']      | Should -Be 'test note value'
        $after2['metrics'] | Should -BeOfType [hashtable]
        [string]$after2['metrics']['delta_usd'] | Should -Be '0.10'
        $after2['exclusions'] | Should -BeOfType [hashtable]
        [string]$after2['exclusions']['recent_count'] | Should -Be '2'
    }

    It 'round-trip handles empty metrics and exclusions blocks (empty-block case)' {
        if (-not (Get-Command Add-RegimeCheckpoint -ErrorAction SilentlyContinue) -or
            -not (Get-Command Get-MostRecentRegimeCheckpoint -ErrorAction SilentlyContinue)) {
            Set-ItResult -Skipped -Because 'core functions not loaded'
            return
        }

        $tmpPath = Join-Path $TestDrive "rt-empty-$([System.Guid]::NewGuid().ToString('N')).yaml"

        # --- Bootstrap call with empty blocks ---
        $entry1 = @{
            id         = 'cp-empty-001'
            timestamp  = '2026-03-01T00:00:00Z'
            sub_issue  = ''
            reason     = 'baseline snapshot'
            metrics    = @{}
            exclusions = @{}
        }
        Add-RegimeCheckpoint -Path $tmpPath -Entry $entry1

        $after1 = Get-MostRecentRegimeCheckpoint -Path $tmpPath
        $after1 | Should -Not -BeNullOrEmpty
        [string]$after1['id']        | Should -Be 'cp-empty-001'
        [string]$after1['timestamp'] | Should -Be '2026-03-01T00:00:00Z'
        [string]$after1['reason']    | Should -Be 'baseline snapshot'
        # sub_issue not written when empty — absent or null
        [string]$after1['sub_issue'] | Should -BeNullOrEmpty
        # metrics/exclusions: hashtable with zero keys
        $after1['metrics']         | Should -BeOfType [hashtable]
        $after1['metrics'].Count   | Should -Be 0
        $after1['exclusions']      | Should -BeOfType [hashtable]
        $after1['exclusions'].Count | Should -Be 0

        # --- Append call with empty blocks ---
        $entry2 = @{
            id         = 'cp-empty-002'
            timestamp  = '2026-04-01T00:00:00Z'
            reason     = 'second snapshot'
            metrics    = @{}
            exclusions = @{}
        }
        Add-RegimeCheckpoint -Path $tmpPath -Entry $entry2

        $after2 = Get-MostRecentRegimeCheckpoint -Path $tmpPath
        $after2 | Should -Not -BeNullOrEmpty
        [string]$after2['id']        | Should -Be 'cp-empty-002'
        [string]$after2['timestamp'] | Should -Be '2026-04-01T00:00:00Z'
        [string]$after2['reason']    | Should -Be 'second snapshot'
        $after2['metrics'].Count    | Should -Be 0
        $after2['exclusions'].Count | Should -Be 0
    }

    It 'round-trip preserves single backslashes in scalar values (writer escape parity)' {
        # Spawned-task fix: the writer previously used `-replace '\\', '\\\\'`
        # in cost-checkpoint-core.ps1, which produces 4 literal backslashes per
        # input `\` because .NET regex replacement treats `\` as literal (only
        # `$` is special). The reader unescapes pairs `\\` → `\`, so 4 in the
        # file became 2 after read — net: each `\` doubled per round-trip.
        # The fix changes the replacement to `'\\'` (2 backslashes literal) so
        # one `\` becomes `\\` in YAML and `\` after read.
        if (-not (Get-Command Add-RegimeCheckpoint -ErrorAction SilentlyContinue) -or
            -not (Get-Command Get-MostRecentRegimeCheckpoint -ErrorAction SilentlyContinue)) {
            Set-ItResult -Skipped -Because 'core functions not loaded'
            return
        }

        $tmpPath = Join-Path $TestDrive "rt-bs-$([System.Guid]::NewGuid().ToString('N')).yaml"

        # Bootstrap call: backslashes in reason (typical case: a Windows-style path).
        $entry1 = @{
            id         = 'cp-bs-001'
            timestamp  = '2026-05-01T00:00:00Z'
            reason     = 'path\to\file'
            metrics    = @{}
            exclusions = @{}
        }
        Add-RegimeCheckpoint -Path $tmpPath -Entry $entry1

        # YAML on disk should contain exactly one `\\` escape per source `\`,
        # i.e. `path\\to\\file` — not `path\\\\to\\\\file`.
        $rawYaml = Get-Content -Path $tmpPath -Raw
        $rawYaml | Should -Match 'reason: "path\\\\to\\\\file"' `
            -Because 'YAML scalar must double each backslash exactly once for valid round-trip'

        $after1 = Get-MostRecentRegimeCheckpoint -Path $tmpPath
        $after1 | Should -Not -BeNullOrEmpty
        [string]$after1['reason'] | Should -Be 'path\to\file' `
            -Because 'round-trip must restore the original single-backslash value'

        # Append call: backslashes in id and reason (multiple fields).
        $entry2 = @{
            id         = 'cp-bs\002'
            timestamp  = '2026-06-01T00:00:00Z'
            reason     = 'mixed \"quote\" and \backslash'
            metrics    = @{}
            exclusions = @{}
        }
        Add-RegimeCheckpoint -Path $tmpPath -Entry $entry2

        $after2 = Get-MostRecentRegimeCheckpoint -Path $tmpPath
        [string]$after2['id']     | Should -Be 'cp-bs\002'
        [string]$after2['reason'] | Should -Be 'mixed \"quote\" and \backslash'
    }
}
