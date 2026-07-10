#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# Pester tests for Get-CostRollingHistory (issue #467, Step 5 TDD).
#
# File under test: .github/scripts/lib/cost-rolling-history.ps1
#
# At Step 5 RED the lib does NOT exist yet, so all It-blocks fail with a
# canonical RED signal: "script not found" or "function not found".
#
# Step 5 GREEN lands the lib and turns these RED signals green.

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
    $script:LibPath = Join-Path $script:RepoRoot '.github/scripts/lib/cost-rolling-history.ps1'
    $script:DefaultCachePath = Join-Path $script:RepoRoot '.github/scripts/cache/cost-rolling-history.json'

    # Dot-source the lib if it exists (GREEN phase). During RED phase this is a no-op.
    if (Test-Path $script:LibPath) {
        . $script:LibPath
    }

    # -------------------------------------------------------------------------
    # Fixture helpers
    # -------------------------------------------------------------------------

    # Build a minimal embedded cost-pattern-data YAML comment body.
    function global:New-CostPatternComment {
        param(
            [string]$Ports = "- name: experience`n    cost_estimate_usd: 0.05",
            [string]$OrchestratorCost = '0.01',
            [string]$Dispatches = 'general_purpose_count: 0',
            [string]$Totals = 'cost_estimate_usd: 0.06',
            [string]$ExcludedField = '',          # e.g. 'excluded_from_rolling_baseline: true'
            [string]$SourceField = '',          # e.g. "source: copilot\n    accessible: false"
            [string]$ExtraTopLevel = ''           # any extra top-level YAML lines
        )
        $excludedLine = if ($ExcludedField) { "`n$ExcludedField" } else { '' }
        $extraLine = if ($ExtraTopLevel) { "`n$ExtraTopLevel" } else { '' }
        $sourceBlock = if ($SourceField) { "`ncost_pattern_data:`n    $SourceField" } else { '' }

        return @"
Some PR comment text before the block.
<!-- cost-pattern-data
ports:
  $Ports
orchestrator_overhead:
  cost_estimate_usd: $OrchestratorCost
dispatches:
  $Dispatches
totals:
  $Totals
$excludedLine$extraLine$sourceBlock
-->
Some text after the block.
"@
    }

        function global:New-Post488CostPatternComment {
                param(
                        [string]$Coverage = 'claude+copilot',
                        [string]$InstallStatus = 'ok',
                        [int]$UnmappedSessionCount = 0,
                        [string]$ProviderSupportLine = 'provider_support: ["claude", "copilot"]',
                        [string]$ProviderBlock = ''
                )

                if ([string]::IsNullOrWhiteSpace($ProviderBlock)) {
                        $ProviderBlock = @"
            claude:
                tokens:
                    input: 1000
                    output: 250
                    cache_creation: 125
                    cache_read: 625
                dispatch_count: 1
                prompt_size_chars: 2200
                cost_estimate_usd: 0.0200
                cache_read_hit_ratio: 0.357
                null_cost_events: 0
                mixed_regime: false
            copilot:
                tokens:
                    input: 500
                    output: 100
                dispatch_count: 1
                prompt_size_chars: 800
                cost_estimate_usd: 0.0000
                cache_metric_unavailable: true
                rate_unavailable: true
                per_token_rates_published: false
"@
                }

                return @"
Some PR comment text before the block.
<!-- cost-pattern-data
version: 1
$ProviderSupportLine
coverage: $Coverage
install_status: $InstallStatus
unmapped_session_count: $UnmappedSessionCount
session_completeness: complete
excluded_from_rolling_baseline: false
ports:
    - name: implement-test
        tokens:
            input: 1500
            output: 350
            cache_creation: 125
            cache_read: 625
        dispatch_count: 2
        prompt_size_chars: 3000
        cost_estimate_usd: 0.0200
        cache_read_hit_ratio: 0.357
        null_cost_events: 0
        mixed_regime: false
        providers:
$ProviderBlock
orchestrator_overhead:
    tokens:
        input: 200
        output: 50
        cache_creation: 0
        cache_read: 0
    cost_estimate_usd: 0.0020
    cache_read_hit_ratio: 0.000
dispatches:
    general_purpose_count: 0
    unattributed_count: 0
totals:
    tokens:
        input: 1700
        output: 400
        cache_creation: 125
        cache_read: 625
    cost_estimate_usd: 0.0220
anomaly_flags: []
-->
Some text after the block.
"@
        }

    # Build a GraphQL success response with one PR containing one comment.
    function global:New-GraphQLResponse {
        param(
            [string[]]$CommentBodies = @()
        )
        $nodes = $CommentBodies | ForEach-Object {
            $escaped = $_ -replace '"', '\"' -replace "`n", '\n' -replace "`r", ''
            "{`"body`":`"$escaped`"}"
        }
        $nodesJson = $nodes -join ','
        return @"
{
  "data": {
    "search": {
      "nodes": [
        {
          "number": 100,
          "comments": {
            "nodes": [$nodesJson]
          }
        }
      ]
    }
  }
}
"@
    }

    # Build a GraphQL response with an errors array (non-empty).
    function global:New-GraphQLErrorResponse {
        return '{"data":null,"errors":[{"message":"some graphql error"}]}'
    }

    # Build a GraphQL response with empty nodes (zero PRs — NOT an error per M19).
    function global:New-GraphQLEmptyNodesResponse {
        return '{"data":{"search":{"nodes":[]}}}'
    }

    # Build a REST pr list response (array of PR numbers).
    function global:New-RestPRListResponse {
        param([int[]]$Numbers = @(100))
        $items = $Numbers | ForEach-Object { "{`"number`":$_}" }
        return '[' + ($items -join ',') + ']'
    }

    # Build a REST pr view comments response for one PR with given comment bodies.
    function global:New-RestPRCommentsResponse {
        param([string[]]$CommentBodies = @())
        $items = $CommentBodies | ForEach-Object {
            $escaped = $_ -replace '"', '\"' -replace "`n", '\n' -replace "`r", ''
            "{`"body`":`"$escaped`"}"
        }
        return '{"comments":[' + ($items -join ',') + ']}'
    }

    # Install a global:gh mock in the calling scope.
    # Pre-builds all response strings before defining global:gh so the mock
    # function can return stored strings directly without calling script:-scoped
    # helpers (which may not be visible from within global:gh in Pester 5).
    function global:Install-GhMock {
        param(
            [string]$GraphQLResponse = $null,    # $null => success with one cost comment
            [int]$GraphQLExitCode = 0,
            [string]$RestPRListResponse = $null,
            [string[]]$RestPRCommentBodies = @(),
            [int]$RestExitCode = 0,
            [switch]$GraphQLSleep,                       # simulate a slow GraphQL call
            [int]$SleepSeconds = 5
        )

        $global:ghCallCount = 0

        # Build GraphQL response string up-front.
        # Use IsNullOrEmpty because [string] params coerce $null to '' in PowerShell.
        $graphqlBody = if (-not [string]::IsNullOrEmpty($GraphQLResponse)) {
            $GraphQLResponse
        }
        else {
            # Default: one PR with one cost comment
            $commentBody = New-CostPatternComment
            New-GraphQLResponse -CommentBodies @($commentBody)
        }

        # Build REST pr-list response string up-front
        $restPRList = if (-not [string]::IsNullOrEmpty($RestPRListResponse)) {
            $RestPRListResponse
        }
        else {
            New-RestPRListResponse -Numbers @(100)
        }

        # Build REST pr-comments response string up-front so global:gh can
        # return it directly without calling any global:-scoped functions.
        $restCommentsResponse = if ($RestPRCommentBodies.Count -gt 0) {
            New-RestPRCommentsResponse -CommentBodies $RestPRCommentBodies
        }
        else {
            $defaultComment = New-CostPatternComment
            New-RestPRCommentsResponse -CommentBodies @($defaultComment)
        }

        $global:mockGraphQLResponse = $graphqlBody
        $global:mockGraphQLExitCode = $GraphQLExitCode
        $global:mockRestPRList = $restPRList
        $global:mockRestCommentsResponse = $restCommentsResponse
        $global:mockRestExitCode = $RestExitCode
        $global:mockGraphQLSleep = $GraphQLSleep.IsPresent
        $global:mockSleepSeconds = $SleepSeconds

        function global:gh {
            param([Parameter(ValueFromRemainingArguments = $true)]$Args)
            $global:ghCallCount++
            $joined = $Args -join ' '

            if ($joined -match 'repo view') {
                $global:LASTEXITCODE = 0
                return '{"owner":{"login":"Grimblaz"},"name":"agent-orchestra"}'
            }

            if ($joined -match 'api graphql') {
                if ($global:mockGraphQLSleep) {
                    Start-Sleep -Seconds $global:mockSleepSeconds
                }
                $global:LASTEXITCODE = $global:mockGraphQLExitCode
                return $global:mockGraphQLResponse
            }

            if ($joined -match 'pr list') {
                $global:LASTEXITCODE = $global:mockRestExitCode
                return $global:mockRestPRList
            }

            if ($joined -match 'pr view \d+ --json comments') {
                $global:LASTEXITCODE = $global:mockRestExitCode
                return $global:mockRestCommentsResponse
            }

            $global:LASTEXITCODE = 0
            return ''
        }
    }
}

AfterAll {
    # Remove global mock if it was installed
    if (Get-Command 'gh' -CommandType Function -ErrorAction SilentlyContinue) {
        # The Function: PSDrive does not honor `global:` in the path — it would
        # be parsed as a function NAME ('global:gh'). Use the bare 'gh' name.
        Remove-Item -Path Function:gh -ErrorAction SilentlyContinue
    }
}

Describe 'Get-CostRollingHistory' {

    BeforeEach {
        # Use a per-test cache path in TestDrive to avoid cross-test pollution
        $script:TestCachePath = Join-Path $TestDrive "cost-rolling-history-$([System.Guid]::NewGuid().ToString('N')).json"
    }

    # Ensure no stale global:gh from a previous describe block leaks in
    BeforeAll {
        if (Get-Command 'gh' -CommandType Function -ErrorAction SilentlyContinue) {
            # The Function: PSDrive does not honor `global:` in the path — it would
            # be parsed as a function NAME ('global:gh'). Use the bare 'gh' name.
            Remove-Item -Path Function:gh -ErrorAction SilentlyContinue
        }
    }

    # -------------------------------------------------------------------------
    # RED signal: if the lib doesn't exist the function won't be defined
    # -------------------------------------------------------------------------

    Context 'RED guard — lib must exist and export function' {

        It 'lib file exists at expected path' {
            $script:LibPath | Should -Exist
        }

        It 'Get-CostRollingHistory function is available after dot-sourcing lib' {
            $fn = Get-Command 'Get-CostRollingHistory' -ErrorAction SilentlyContinue
            $fn | Should -Not -BeNullOrEmpty
        }
    }

    # -------------------------------------------------------------------------
    # Cache behavior
    # -------------------------------------------------------------------------

    Context 'cache behavior' {

        It 'returns cached data when cache is fresh (< 1 hour)' {
            # Write a fresh cache file (modified just now)
            $cachedEntry = @{ ports = @{}; orchestrator_overhead = @{}; dispatches = @{}; totals = @{} }
            $cachedData = @{ entries = @($cachedEntry); generated_at = (Get-Date).ToUniversalTime().ToString('o') }
            $cachedData | ConvertTo-Json -Depth 10 | Set-Content -Path $script:TestCachePath -Encoding UTF8

            # Mock gh — should NOT be called if cache is fresh
            Install-GhMock
            $global:ghCallCount = 0

            $result = Get-CostRollingHistory -CachePath $script:TestCachePath -RepoRoot $script:RepoRoot

            $result | Should -Not -BeNullOrEmpty
            $result.timed_out | Should -Be $false
            # Cache hit: gh should not have been called for graphql or pr list
            $global:ghCallCount | Should -Be 0 -Because 'fresh cache should be returned without fetching'
        }

        It 'fetches fresh data when cache is expired' {
            # Write a cache file with a timestamp > 1 hour old
            $oldTime = (Get-Date).AddHours(-2).ToUniversalTime().ToString('o')
            $staleData = @{ entries = @(); generated_at = $oldTime }
            $staleData | ConvertTo-Json -Depth 10 | Set-Content -Path $script:TestCachePath -Encoding UTF8

            Install-GhMock
            $global:ghCallCount = 0

            $result = Get-CostRollingHistory -CachePath $script:TestCachePath -RepoRoot $script:RepoRoot -TimeoutSeconds 30

            $result | Should -Not -BeNullOrEmpty
            $result.timed_out | Should -Be $false
            # Stale cache: gh should have been called to fetch fresh data
            $global:ghCallCount | Should -BeGreaterThan 0 -Because 'expired cache should trigger a fresh fetch'
        }

        It 'fetches fresh data when cache file does not exist' {
            # Ensure the cache file does NOT exist
            if (Test-Path $script:TestCachePath) { Remove-Item $script:TestCachePath -Force }

            Install-GhMock
            $global:ghCallCount = 0

            $result = Get-CostRollingHistory -CachePath $script:TestCachePath -RepoRoot $script:RepoRoot -TimeoutSeconds 30

            $result | Should -Not -BeNullOrEmpty
            $result.timed_out | Should -Be $false
            $global:ghCallCount | Should -BeGreaterThan 0 -Because 'missing cache should trigger a fresh fetch'
        }

        It 'force-refresh deletes cache and fetches fresh even within TTL' {
            # Write a fresh cache file (modified just now)
            $freshData = @{ entries = @(); generated_at = (Get-Date).ToUniversalTime().ToString('o') }
            $freshData | ConvertTo-Json -Depth 10 | Set-Content -Path $script:TestCachePath -Encoding UTF8

            Install-GhMock
            $global:ghCallCount = 0

            $result = Get-CostRollingHistory -CachePath $script:TestCachePath -ForceRefresh -RepoRoot $script:RepoRoot -TimeoutSeconds 30

            $result | Should -Not -BeNullOrEmpty
            $result.timed_out | Should -Be $false
            # ForceRefresh must bypass cache and fetch fresh
            $global:ghCallCount | Should -BeGreaterThan 0 -Because '-ForceRefresh should bypass even a fresh cache'
        }
    }

    # -------------------------------------------------------------------------
    # GraphQL -> REST fallback
    # -------------------------------------------------------------------------

    Context 'GraphQL -> REST fallback' {

        It 'uses GraphQL when available (exit 0, valid response)' {
            $commentBody = New-CostPatternComment
            $graphqlResp = New-GraphQLResponse -CommentBodies @($commentBody)
            Install-GhMock -GraphQLResponse $graphqlResp -GraphQLExitCode 0

            $result = Get-CostRollingHistory -CachePath $script:TestCachePath -RepoRoot $script:RepoRoot -TimeoutSeconds 30

            $result.timed_out | Should -Be $false
            $result.entries.Count | Should -BeGreaterThan 0 -Because 'GraphQL success should yield parsed entries'
        }

        It 'falls back to REST when GraphQL exits non-zero' {
            $commentBody = New-CostPatternComment
            # GraphQL exits non-zero; REST should yield entries via pr list + pr view
            Install-GhMock `
                -GraphQLResponse '{"data":null}' `
                -GraphQLExitCode 1 `
                -RestPRCommentBodies @($commentBody)

            $result = Get-CostRollingHistory -CachePath $script:TestCachePath -RepoRoot $script:RepoRoot -TimeoutSeconds 30

            $result.timed_out | Should -Be $false
            $result.entries.Count | Should -BeGreaterThan 0 -Because 'REST fallback should yield parsed entries'
        }

        It 'falls back to REST when GraphQL response has non-empty errors[]' {
            $commentBody = New-CostPatternComment
            Install-GhMock `
                -GraphQLResponse (New-GraphQLErrorResponse) `
                -GraphQLExitCode 0 `
                -RestPRCommentBodies @($commentBody)

            $result = Get-CostRollingHistory -CachePath $script:TestCachePath -RepoRoot $script:RepoRoot -TimeoutSeconds 30

            $result.timed_out | Should -Be $false
            $result.entries.Count | Should -BeGreaterThan 0 -Because 'errors[] in response should trigger REST fallback'
        }

        It 'falls back to REST when GraphQL response shape is unparseable' {
            $commentBody = New-CostPatternComment
            Install-GhMock `
                -GraphQLResponse 'not valid json at all }{' `
                -GraphQLExitCode 0 `
                -RestPRCommentBodies @($commentBody)

            $result = Get-CostRollingHistory -CachePath $script:TestCachePath -RepoRoot $script:RepoRoot -TimeoutSeconds 30

            $result.timed_out | Should -Be $false
            $result.entries.Count | Should -BeGreaterThan 0 -Because 'parse failure should trigger REST fallback'
        }

        It 'does NOT fall back when GraphQL returns 200 with empty nodes (zero PRs)' {
            # M19 regression: data.search.nodes:[] is a valid "zero PRs" result — NOT a fallback trigger.
            Install-GhMock `
                -GraphQLResponse (New-GraphQLEmptyNodesResponse) `
                -GraphQLExitCode 0

            $result = Get-CostRollingHistory -CachePath $script:TestCachePath -RepoRoot $script:RepoRoot -TimeoutSeconds 30

            $result.timed_out | Should -Be $false
            $result.entries.Count | Should -Be 0 -Because 'empty nodes is a valid zero-PR result, not a fallback trigger'
            # Verify REST was NOT called (pr list should not appear in call log)
            # We check that ghCallCount did not include a pr list call by ensuring
            # no REST pr list was triggered — the function should have returned cleanly.
            # A proxy check: entries is empty and no error thrown.
        }
    }

    # -------------------------------------------------------------------------
    # Exclusions
    # -------------------------------------------------------------------------

    Context 'exclusions' {

        It 'skips comments with excluded_from_rolling_baseline: true' {
            $excludedComment = New-CostPatternComment -ExcludedField 'excluded_from_rolling_baseline: true'
            $graphqlResp = New-GraphQLResponse -CommentBodies @($excludedComment)
            Install-GhMock -GraphQLResponse $graphqlResp

            $result = Get-CostRollingHistory -CachePath $script:TestCachePath -RepoRoot $script:RepoRoot -TimeoutSeconds 30

            $result.timed_out | Should -Be $false
            $result.entries.Count | Should -Be 0 -Because 'excluded_from_rolling_baseline:true should be skipped'
        }

        It 'skips Copilot-source inaccessible comments' {
            $copilotInaccessible = New-CostPatternComment -SourceField "source: copilot`n    accessible: false"
            $graphqlResp = New-GraphQLResponse -CommentBodies @($copilotInaccessible)
            Install-GhMock -GraphQLResponse $graphqlResp

            $result = Get-CostRollingHistory -CachePath $script:TestCachePath -RepoRoot $script:RepoRoot -TimeoutSeconds 30

            $result.timed_out | Should -Be $false
            $result.entries.Count | Should -Be 0 -Because 'copilot-source inaccessible comments should be skipped'
        }

        It 'includes comments without excluded_from_rolling_baseline field' {
            # A normal comment with no exclusion fields
            $normalComment = New-CostPatternComment
            $graphqlResp = New-GraphQLResponse -CommentBodies @($normalComment)
            Install-GhMock -GraphQLResponse $graphqlResp

            $result = Get-CostRollingHistory -CachePath $script:TestCachePath -RepoRoot $script:RepoRoot -TimeoutSeconds 30

            $result.timed_out | Should -Be $false
            $result.entries.Count | Should -Be 1 -Because 'normal comment without exclusion should be included'
        }
    }

    # -------------------------------------------------------------------------
    # Timeout
    # -------------------------------------------------------------------------

    Context 'timeout' {

        It 'returns timed_out sentinel when budget exceeded' {
            # Use a job to run the function with a very short budget so the test
            # completes in bounded wall-clock time.
            #
            # Strategy: the mock makes 'gh repo view' sleep for 3 seconds.
            # TimeoutSeconds=2 means CheckBudget fires right after repo view
            # returns (elapsed ~3s > 2s budget) and returns the timed_out sentinel.
            # This avoids the inner-job/mock-isolation problem: all gh calls run
            # in-process in the same job and the mock is visible.
            $job = Start-Job -ScriptBlock {
                param($LibPath, $CachePath, $RepoRoot)
                if (Test-Path $LibPath) { . $LibPath }

                # Install a gh mock in the job context.
                # repo view sleeps 3s to push elapsed time past the 2s budget.
                function global:gh {
                    param([Parameter(ValueFromRemainingArguments = $true)]$Args)
                    $joined = $Args -join ' '
                    if ($joined -match 'repo view') {
                        # Sleep past the budget
                        Start-Sleep -Seconds 3
                        $global:LASTEXITCODE = 0
                        return '{"owner":{"login":"Grimblaz"},"name":"agent-orchestra"}'
                    }
                    $global:LASTEXITCODE = 0
                    return ''
                }

                $result = Get-CostRollingHistory `
                    -CachePath $CachePath `
                    -RepoRoot $RepoRoot `
                    -TimeoutSeconds 2

                return $result
            } -ArgumentList $script:LibPath, $script:TestCachePath, $script:RepoRoot

            # Wait up to 15 seconds for the job; the function should return within ~5s
            $completed = Wait-Job -Job $job -Timeout 15
            $completed | Should -Not -BeNullOrEmpty -Because 'function should return before outer 15s wall-clock limit'

            $result = Receive-Job -Job $job
            Remove-Job -Job $job -Force

            $result | Should -Not -BeNullOrEmpty
            $result.timed_out | Should -Be $true -Because 'TimeoutSeconds=2 with 3s repo-view sleep should return timed_out sentinel'
            $result.entries.Count | Should -Be 0
        }
    }

    # -------------------------------------------------------------------------
    # Result shape
    # -------------------------------------------------------------------------

    Context 'result shape' {

        It 'returns entries array from parsed cost-pattern-data YAML blocks' {
            $comment = New-CostPatternComment `
                -Ports "- name: experience`n    cost_estimate_usd: 0.05" `
                -OrchestratorCost '0.01' `
                -Dispatches 'general_purpose_count: 0' `
                -Totals 'cost_estimate_usd: 0.06'
            $graphqlResp = New-GraphQLResponse -CommentBodies @($comment)
            Install-GhMock -GraphQLResponse $graphqlResp

            $result = Get-CostRollingHistory -CachePath $script:TestCachePath -RepoRoot $script:RepoRoot -TimeoutSeconds 30

            $result | Should -Not -BeNullOrEmpty
            $result.timed_out | Should -Be $false
            $result.entries | Should -Not -BeNullOrEmpty
            $result.entries.Count | Should -BeGreaterThan 0

            # Each entry should be a hashtable with the expected top-level keys
            $entry = $result.entries[0]
            $entry | Should -Not -BeNullOrEmpty
            $entry.ContainsKey('ports') | Should -Be $true -Because 'entry must have ports key'
            $entry.ContainsKey('orchestrator_overhead') | Should -Be $true -Because 'entry must have orchestrator_overhead key'
            $entry.ContainsKey('dispatches') | Should -Be $true -Because 'entry must have dispatches key'
            $entry.ContainsKey('totals') | Should -Be $true -Because 'entry must have totals key'
        }

        It 'ports in entries are returned as a dictionary keyed by port name (not an array) — Fix Pass1-F10' {
            # Regression test: ConvertFrom-CostPatternYaml must return ports as a hashtable/dictionary
            # (keyed by port name) so Get-MetricValue can call $Entry.ports.ContainsKey($Port).
            # Before the fix, ports was an array, causing ContainsKey() failures.
            $comment = New-CostPatternComment `
                -Ports "- name: experience`n    cost_estimate_usd: 0.05`n    dispatch_count: 2"
            $graphqlResp = New-GraphQLResponse -CommentBodies @($comment)
            Install-GhMock -GraphQLResponse $graphqlResp

            $result = Get-CostRollingHistory -CachePath $script:TestCachePath -RepoRoot $script:RepoRoot -TimeoutSeconds 30

            $result.timed_out | Should -Be $false
            $result.entries.Count | Should -Be 1
            $entry = $result.entries[0]
            # ports must be a hashtable with ContainsKey — not an array
            $entry['ports'] | Should -BeOfType [hashtable] -Because 'ports must be a dictionary, not an array'
            $entry['ports'].ContainsKey('experience') | Should -Be $true
            $entry['ports']['experience']['dispatch_count'] | Should -Be 2
        }

        It 'tokens subfields are parsed from ports YAML block — Fix Pass1-F10' {
            # The tokens: sub-block under each port entry must be parsed so that
            # Get-MetricValue can compute tokens.per_dispatch.avg.output/input.
            $portsYaml = @"
- name: experience
    cost_estimate_usd: 0.05
    dispatch_count: 3
    tokens:
      input: 1200
      output: 400
      cache_creation: 50
      cache_read: 300
"@
            $comment = New-CostPatternComment -Ports $portsYaml.TrimStart()
            $graphqlResp = New-GraphQLResponse -CommentBodies @($comment)
            Install-GhMock -GraphQLResponse $graphqlResp

            $result = Get-CostRollingHistory -CachePath $script:TestCachePath -RepoRoot $script:RepoRoot -TimeoutSeconds 30

            $result.timed_out | Should -Be $false
            $result.entries.Count | Should -Be 1
            $port = $result.entries[0]['ports']['experience']
            $port['tokens']['input']          | Should -Be 1200
            $port['tokens']['output']         | Should -Be 400
            $port['tokens']['cache_creation'] | Should -Be 50
            $port['tokens']['cache_read']     | Should -Be 300
        }

        It 'extracts sub-issue refs as structured field with word boundaries (Pass2-F4)' {
            # Regression: -SubIssue filter previously regex-matched against
            # raw comment_body, which (a) bloated cache by carrying multi-KB
            # bodies through, and (b) had no word boundary so '#469' matched
            # inside '#4690'. The fix projects sub-issue refs into a
            # structured list at parse time using word-boundary regex.
            $bodyText = @"
Closes #469. See also #4690 (different issue) and #470.

<!-- cost-pattern-data
version: 1
session_completeness: complete
generated_at: 2026-04-15T12:00:00Z
pr: 999
branch: feature/issue-469-foo
ports:
- name: experience
    cost_estimate_usd: 0.05
orchestrator_overhead:
  cost_estimate_usd: 0.01
dispatches:
  general_purpose_count: 1
  unattributed_count: 0
totals:
  cost_estimate_usd: 0.06
-->
"@
            $graphqlResp = New-GraphQLResponse -CommentBodies @($bodyText)
            Install-GhMock -GraphQLResponse $graphqlResp

            $result = Get-CostRollingHistory -CachePath $script:TestCachePath -RepoRoot $script:RepoRoot -TimeoutSeconds 30

            $result.timed_out | Should -Be $false
            $result.entries.Count | Should -Be 1
            $entry = $result.entries[0]
            $entry.ContainsKey('sub_issue_refs') | Should -Be $true -Because 'each entry must carry structured sub-issue refs for downstream filters'
            $refs = @($entry['sub_issue_refs'])
            # Word-boundary regex: #469, #4690, #470 are three distinct refs.
            # The filter must see all of them as separate strings, NOT match
            # '#469' inside '#4690' (which the previous regex.Escape() impl did).
            $refs | Should -Contain '#469'
            $refs | Should -Contain '#4690'
            $refs | Should -Contain '#470'
            # Critical: '#469' and '#4690' are present as DISTINCT entries —
            # confirms the boundary regex distinguishes them.
            ($refs | Where-Object { $_ -eq '#469' }).Count | Should -Be 1
            ($refs | Where-Object { $_ -eq '#4690' }).Count | Should -Be 1
        }

        It 'maps session_completeness->completeness and generated_at->rendered_at at the parse boundary (Fix #760-T3)' {
            # ConvertFrom-CostPatternYaml projects the renderer's `session_completeness`
            # and `generated_at` fields onto the `completeness` / `rendered_at` keys that
            # Resolve-CostDataPreservation reads. Without these mappings the preservation
            # gate silently sees null completeness and clobbers a complete prior block.
            # The integration AC2 test hand-builds the flat shape and bypasses the parser,
            # so this asserts the mappings directly — a revert of either line fails here.
            $bodyText = @"
<!-- cost-pattern-data
version: 1
session_completeness: complete
generated_at: 2026-05-20T08:30:00Z
pr: 1234
branch: feature/issue-760-t3
ports:
- name: experience
    cost_estimate_usd: 0.05
orchestrator_overhead:
  cost_estimate_usd: 0.01
dispatches:
  general_purpose_count: 1
  unattributed_count: 0
totals:
  cost_estimate_usd: 0.06
-->
"@
            $graphqlResp = New-GraphQLResponse -CommentBodies @($bodyText)
            Install-GhMock -GraphQLResponse $graphqlResp

            $result = Get-CostRollingHistory -CachePath $script:TestCachePath -RepoRoot $script:RepoRoot -TimeoutSeconds 30

            $result.timed_out | Should -Be $false
            $result.entries.Count | Should -Be 1
            $entry = $result.entries[0]
            # Both source field and mapped alias must be populated.
            $entry['session_completeness'] | Should -Be 'complete'
            $entry['completeness']         | Should -Be 'complete' -Because 'preservation gate reads $Prior[''completeness'']'
            $entry['generated_at']         | Should -Be '2026-05-20T08:30:00Z'
            $entry['rendered_at']          | Should -Be '2026-05-20T08:30:00Z' -Because 'preservation notice reads $Prior[''rendered_at'']'
        }

        It 'returns empty entries array when no matching comments found (GraphQL 200 empty)' {
            # M19 regression: zero nodes is a valid zero-PR result
            Install-GhMock -GraphQLResponse (New-GraphQLEmptyNodesResponse) -GraphQLExitCode 0

            $result = Get-CostRollingHistory -CachePath $script:TestCachePath -RepoRoot $script:RepoRoot -TimeoutSeconds 30

            $result | Should -Not -BeNullOrEmpty
            $result.timed_out | Should -Be $false
            # entries key must be present and be an array (even if empty — @() is a valid empty result)
            $result.ContainsKey('entries') | Should -Be $true -Because 'entries key must always be present'
            $null -ne $result.entries | Should -Be $true -Because 'entries must not be $null'
            @($result.entries).Count | Should -Be 0
        }
    }

    Context 'post-#488 YAML parser forward compatibility' {

        It 'defaults missing coverage and install fields for pre-#488 v1 YAML' {
            $comment = New-CostPatternComment
            $graphqlResp = New-GraphQLResponse -CommentBodies @($comment)
            Install-GhMock -GraphQLResponse $graphqlResp

            $result = Get-CostRollingHistory -CachePath $script:TestCachePath -RepoRoot $script:RepoRoot -TimeoutSeconds 30

            $result.timed_out | Should -Be $false
            $result.entries.Count | Should -Be 1
            $entry = $result.entries[0]
            $entry['coverage'] | Should -Be 'claude-only'
            $entry['install_status'] | Should -Be 'ok'
            $entry['unmapped_session_count'] | Should -Be 0
        }

        It 'parses post-#488 additive top-level and per-port provider fields' {
            $comment = New-Post488CostPatternComment
            $graphqlResp = New-GraphQLResponse -CommentBodies @($comment)
            Install-GhMock -GraphQLResponse $graphqlResp

            $result = Get-CostRollingHistory -CachePath $script:TestCachePath -RepoRoot $script:RepoRoot -TimeoutSeconds 30

            $result.timed_out | Should -Be $false
            $result.entries.Count | Should -Be 1
            $entry = $result.entries[0]

            @($entry['provider_support']) | Should -Be @('claude', 'copilot')
            $entry['coverage'] | Should -Be 'claude+copilot'
            $entry['install_status'] | Should -Be 'ok'
            $entry['unmapped_session_count'] | Should -Be 0
            $entry['ports'].ContainsKey('implement-test') | Should -Be $true
            $entry['ports']['implement-test']['providers']['claude']['dispatch_count'] | Should -Be 1
            $entry['ports']['implement-test']['providers']['copilot']['cache_metric_unavailable'] | Should -Be $true
        }

        It 'parses provider subobjects with two-space provider indentation' {
            $providerBlock = @"
      claude:
        tokens:
          input: 1000
          output: 250
          cache_creation: 125
          cache_read: 625
        dispatch_count: 1
        cost_estimate_usd: 0.0200
        cache_read_hit_ratio: 0.357
      copilot:
        tokens:
          input: 500
          output: 100
        dispatch_count: 1
        cost_estimate_usd: 0.0000
        cache_metric_unavailable: true
"@
            $comment = New-Post488CostPatternComment -ProviderBlock $providerBlock
            $graphqlResp = New-GraphQLResponse -CommentBodies @($comment)
            Install-GhMock -GraphQLResponse $graphqlResp

            $result = Get-CostRollingHistory -CachePath $script:TestCachePath -RepoRoot $script:RepoRoot -TimeoutSeconds 30

            $result.timed_out | Should -Be $false
            $providers = $result.entries[0]['ports']['implement-test']['providers']
            $providers | Should -Not -BeNullOrEmpty -Because 'post-#488 parser must preserve per-port providers subobjects'
            $providers | Should -BeOfType [hashtable]
            $providers.ContainsKey('claude') | Should -Be $true
            $providers.ContainsKey('copilot') | Should -Be $true
        }

        It 'does not turn Copilot cache-metric-unavailable rows into zero cache-hit baseline values' {
            $comment = New-Post488CostPatternComment
            $graphqlResp = New-GraphQLResponse -CommentBodies @($comment)
            Install-GhMock -GraphQLResponse $graphqlResp

            $result = Get-CostRollingHistory -CachePath $script:TestCachePath -RepoRoot $script:RepoRoot -TimeoutSeconds 30

            $providers = $result.entries[0]['ports']['implement-test']['providers']
            $providers | Should -Not -BeNullOrEmpty -Because 'post-#488 parser must preserve provider rows before cache baselines can filter Copilot rows'
            $copilotProvider = $providers['copilot']
            $copilotProvider | Should -Not -BeNullOrEmpty
            $copilotProvider['cache_metric_unavailable'] | Should -Be $true
            $copilotProvider.ContainsKey('cache_read_hit_ratio') | Should -Be $false -Because 'Copilot rows must be skipped for cache_read.hit_ratio, not included as 0.0 values'
        }

        It 'carries coverage and install-status outcomes for the cross-tool collection matrix' -TestCases @(
            @{ Scenario = 'sentinel-present + Copilot-events-merged'; Coverage = 'claude+copilot'; InstallStatus = 'ok'; Unmapped = 0; SupportLine = 'provider_support: ["claude", "copilot"]' }
            @{ Scenario = 'sentinel-present + Copilot-reflog-no-match'; Coverage = 'claude-only-with-copilot-fallback-warning'; InstallStatus = 'ok'; Unmapped = 2; SupportLine = 'provider_support: ["claude"]' }
            @{ Scenario = 'sentinel-absent + fallback Copilot events'; Coverage = 'claude-only-with-copilot-fallback-warning'; InstallStatus = 'missing-or-fallback'; Unmapped = 0; SupportLine = 'provider_support: ["claude"]' }
            @{ Scenario = 'sentinel-absent + no Copilot data'; Coverage = 'claude-only'; InstallStatus = 'missing-or-fallback'; Unmapped = 0; SupportLine = 'provider_support: ["claude"]' }
        ) {
            param([string]$Scenario, [string]$Coverage, [string]$InstallStatus, [int]$Unmapped, [string]$SupportLine)

            $comment = New-Post488CostPatternComment `
                -Coverage $Coverage `
                -InstallStatus $InstallStatus `
                -UnmappedSessionCount $Unmapped `
                -ProviderSupportLine $SupportLine
            $graphqlResp = New-GraphQLResponse -CommentBodies @($comment)
            Install-GhMock -GraphQLResponse $graphqlResp

            $result = Get-CostRollingHistory -CachePath $script:TestCachePath -RepoRoot $script:RepoRoot -TimeoutSeconds 30

            $entry = $result.entries[0]
            $entry['coverage'] | Should -Be $Coverage -Because $Scenario
            $entry['install_status'] | Should -Be $InstallStatus -Because $Scenario
            $entry['unmapped_session_count'] | Should -Be $Unmapped -Because $Scenario
        }
    }

    Context 'baseline-eligibility additive fields round-trip (issue #824 s2)' {

        BeforeAll {
            $script:RendererLibPath = Join-Path $script:RepoRoot '.github/scripts/lib/cost-pattern-renderer.ps1'
            if (Test-Path $script:RendererLibPath) {
                . $script:RendererLibPath
            }
        }

        It 'capture_point, session_id, head_ref, and pr survive a render->parse round trip' {
            # True render->parse round trip: renders via the real Format-CostPatternYaml
            # (not a hand-typed fixture) and parses the result back via the real
            # Get-CostRollingHistory -> ConvertFrom-CostPatternYaml pipeline. The renderer
            # already emitted `pr:` before this fix; the parser had no matcher for it.
            $attribution = @{
                ports                 = @{
                    'implement-code' = @{
                        tokens               = @{ input = 100; output = 50; cache_creation = 0; cache_read = 0 }
                        dispatch_count       = 1
                        cost_estimate_usd    = 0.01
                        cache_read_hit_ratio = 0.0
                        mixed_regime         = $false
                    }
                }
                orchestrator_overhead = @{
                    tokens               = @{ input = 10; output = 5; cache_creation = 0; cache_read = 0 }
                    cost_estimate_usd    = 0.001
                    cache_read_hit_ratio = 0.0
                }
                dispatches            = @{ general_purpose_count = 0; unattributed_count = 0 }
                totals                = @{
                    tokens            = @{ input = 110; output = 55; cache_creation = 0; cache_read = 0 }
                    cost_estimate_usd = 0.011
                }
            }
            $completeness = @{
                completeness                   = 'partial'
                stop_reason                    = 'tool_use'
                excluded_from_rolling_baseline = $false
                exclude_reason                 = $null
                capture_point                  = 'pr-creation-mid-session'
            }

            $rendered = Format-CostPatternYaml `
                -Attribution $attribution `
                -Completeness $completeness `
                -Pr 824 `
                -Branch 'feature/issue-824-baseline-eligibility' `
                -SessionId 'session-abc-123' `
                -HeadRef 'feature/issue-824-baseline-eligibility'

            $commentBody = "Some PR comment text before the block.`n$rendered`nSome text after the block."
            $graphqlResp = New-GraphQLResponse -CommentBodies @($commentBody)
            Install-GhMock -GraphQLResponse $graphqlResp

            $result = Get-CostRollingHistory -CachePath $script:TestCachePath -RepoRoot $script:RepoRoot -TimeoutSeconds 30

            $result.timed_out | Should -Be $false
            $result.entries.Count | Should -Be 1
            $entry = $result.entries[0]

            $entry['capture_point'] | Should -Be 'pr-creation-mid-session'
            $entry['session_id']    | Should -Be 'session-abc-123'
            $entry['head_ref']      | Should -Be 'feature/issue-824-baseline-eligibility'
            $entry['pr']            | Should -Be 824
        }
    }
}
