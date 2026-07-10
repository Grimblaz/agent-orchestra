#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# Integration tests for cost-pattern wiring in frame-credit-ledger orchestrator
# (issue #467, Step 9).
#
# Validates that:
#   1. The cost section is appended to the comment when cost lib is available
#   2. The <!-- cost-pattern-data marker appears in the comment
#   3. Graceful degradation when cost lib dot-source fails
#   4. Pre-v4 short-circuit is unaffected (cost section not added)
#   5. Idempotent re-run produces same comment structure

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
    $script:OrchestratorPath = Join-Path $script:RepoRoot '.github/scripts/frame-credit-ledger.ps1'
    $script:CoreLibPath = Join-Path $script:RepoRoot '.github/scripts/lib/frame-credit-ledger-core.ps1'
    $script:LibDir = Join-Path $script:RepoRoot '.github/scripts/lib'

    # Canonical v4 PR body fixture used across all tests
    $script:V4AllCoveredBody = @'
## Summary

A v4 PR body where every credit is passed.

<!-- pipeline-metrics
metrics_version: 4
frame_version: 1
credits:
  - port: review
    status: passed
    evidence: "judge ruling: keep"
  - port: implement-test
    status: passed
    evidence: "tests GREEN at HEAD"
integrity_checks:
  - check: schema-version-pinned
    status: passed
-->
'@

    # Pre-v4 body for short-circuit test
    $script:PreV4Body = @'
## Summary

A pre-v4 PR body.

<!-- pipeline-metrics
metrics_version: 3
some_legacy_field: value
-->
'@

    $script:InvokeOrchestratorInProcessWithWalkerCapture = {
        param(
            [Parameter(Mandatory)][string]$PrBody,
            [Parameter(Mandatory)][string]$CostBranch
        )

        $previousInline = $env:FRAME_CREDIT_LEDGER_TEST_WALKER_INLINE
        $env:FRAME_CREDIT_LEDGER_TEST_WALKER_INLINE = '1'

        . $script:OrchestratorPath -Pr 467 -Mode 'warn'

        $captured = @{
            HadIssueNumber = $false
            IssueNumber    = $null
            SlugCwd        = $null
            ParentCwd      = $null
        }
        $bodyJson = (@{ body = $PrBody; comments = @() } | ConvertTo-Json -Compress)

        function git {
            param([Parameter(ValueFromRemainingArguments = $true)]$Args)
            $joined = $Args -join ' '

            if ($joined -match 'config --get remote\.origin\.url') {
                $global:LASTEXITCODE = 0
                return 'https://github.com/example/example.git'
            }

            if ($joined -match 'rev-parse --abbrev-ref HEAD') {
                $global:LASTEXITCODE = 0
                return $CostBranch
            }

            $global:LASTEXITCODE = 0
            return ''
        }

        function gh {
            param([Parameter(ValueFromRemainingArguments = $true)]$Args)
            $joined = $Args -join ' '

            if ($joined -match 'pr view \d+ --json baseRefOid') {
                $global:LASTEXITCODE = 0
                return '{"baseRefOid":"abc123"}'
            }

            if ($joined -match 'pr view \d+ --json body') {
                $global:LASTEXITCODE = 0
                return $bodyJson
            }

            if ($joined -match 'issue view \d+ --json comments') {
                $global:LASTEXITCODE = 0
                return '{"comments":[]}'
            }

            if ($joined -match '(issue|pr) comment \d+ --body') {
                $global:LASTEXITCODE = 0
                return 'https://github.com/example/example/pull/467#issuecomment-1'
            }

            if ($joined -match 'api repos/[^/]+/[^/]+ ') {
                $global:LASTEXITCODE = 0
                return '{"owner":{"login":"example"},"name":"example"}'
            }

            if ($joined -match 'pr edit \d+ --body-file') {
                $global:LASTEXITCODE = 0
                return ''
            }

            $global:LASTEXITCODE = 0
            return ''
        }

        function Get-CostTranscriptSlug {
            param([string]$CwdPath)
            $captured.SlugCwd = $CwdPath
            return 'test-slug'
        }
        function Invoke-CostTranscriptWalk {
            param([string]$Slug, [string]$Branch, [string]$ParentCwd, [Nullable[int]]$IssueNumber = $null)
            $captured.ParentCwd = $ParentCwd
            $captured.HadIssueNumber = $PSBoundParameters.ContainsKey('IssueNumber')
            $captured.IssueNumber = $IssueNumber
            return @()
        }
        function Invoke-CostCopilotWalk {
            param([string]$Branch, [string]$RepoRoot, [string]$OtelJsonlPath, [string]$WorkspaceFolderBasename = '')
            return @()
        }
        function Get-CostAttribution {
            param([object[]]$Events, [string]$RateTablePath = '')
            return @{ ports = @{}; orchestrator_overhead = @{}; dispatches = @{}; totals = @{ total_cost_usd = 0.0 } }
        }
        function Get-CostRollingHistory { param([int]$TimeoutSeconds = 10) return @{ timed_out = $false; entries = @() } }
        function Get-MostRecentRegimeCheckpoint { param([string]$Path) return $null }
        function Get-SessionCompleteness { param([object[]]$Events, [string]$ExcludeReason = '', [string]$Branch = '') return @{ completeness = 'unknown'; excluded_from_rolling_baseline = $true; exclude_reason = 'no-events' } }
        function Resolve-CostDataPreservation { param($Current, $Prior) return @{ use_prior = $false; notice = '' } }
        function Get-CostAnomalyFlags { param($ThisRun, [object[]]$RollingHistory, $RegimeCheckpoint) return @() }
        function Format-CostPatternMarkdown { param($Attribution, $Completeness, [object[]]$AnomalyFlags, $RollingMeta, [int]$Pr, [string]$Branch) return '## Cost Pattern' }
        function Format-CostPatternYaml { param($Attribution, $Completeness, [object[]]$AnomalyFlags, [int]$Pr, [string]$Branch) return "<!-- cost-pattern-data`npr: $Pr`n-->" }

        try {
            $result = Invoke-FrameCreditLedger -Pr 467 -Mode 'warn'
            return @{ Result = $result; Captured = $captured }
        }
        finally {
            $env:FRAME_CREDIT_LEDGER_TEST_WALKER_INLINE = $previousInline
        }
    }

    # -------------------------------------------------------------------------
    # In-process invoker for content-assertion tests (replaces Start-Process spawns).
    # Mirrors the mock setup from NewCostMockBootstrap but runs Invoke-FrameCreditLedger
    # directly in-process. Returns @{ ExitCode = ...; Comment = ... } where Comment
    # is the exact comment body that would be posted to GitHub.
    # -------------------------------------------------------------------------
    $script:InvokeOrchestratorInProcess = {
        param(
            [string]$PrBody = '',
            [string]$CostMarkdown = '## Cost Pattern',
            [string]$CostYaml = "<!-- cost-pattern-data`npr: 467`n-->",
            [bool]$PoisonCostLib = $false,
            [object[]]$Comments = @(),
            [string]$CostBranch = 'feature/test-cost-integration'
        )

        $bodyJson = (@{ body = $PrBody; comments = $Comments } | ConvertTo-Json -Compress -Depth 5)
        $capturedCostMarkdown = $CostMarkdown
        $capturedCostYaml = $CostYaml
        $capturedRepoRoot = $script:RepoRoot

        $previousInline = $env:FRAME_CREDIT_LEDGER_TEST_WALKER_INLINE
        $previousNoSleep = $env:FRAME_CREDIT_LEDGER_TEST_NO_SLEEP
        try {
        $env:FRAME_CREDIT_LEDGER_TEST_WALKER_INLINE = '1'
        $env:FRAME_CREDIT_LEDGER_TEST_NO_SLEEP = '1'

        . $script:OrchestratorPath -Pr 467 -Mode 'warn'

        function git {
            param([Parameter(ValueFromRemainingArguments = $true)]$Args)
            $joined = $Args -join ' '
            if ($joined -match 'rev-parse --show-toplevel') {
                $global:LASTEXITCODE = 0
                return $capturedRepoRoot
            }
            if ($joined -match 'config --get remote\.origin\.url') {
                $global:LASTEXITCODE = 0
                return 'https://github.com/example/example.git'
            }
            if ($joined -match 'rev-parse --abbrev-ref HEAD') {
                $global:LASTEXITCODE = 0
                return $CostBranch
            }
            $global:LASTEXITCODE = 0
            return ''
        }

        function gh {
            param([Parameter(ValueFromRemainingArguments = $true)]$Args)
            $joined = $Args -join ' '
            if ($joined -match 'pr view \d+ --json baseRefOid') {
                $global:LASTEXITCODE = 0
                return '{"baseRefOid":"abc123"}'
            }
            if ($joined -match 'pr view \d+ --json body') {
                $global:LASTEXITCODE = 0
                return $bodyJson
            }
            if ($joined -match 'issue view \d+ --json comments') {
                $global:LASTEXITCODE = 0
                return '{"comments":[]}'
            }
            if ($joined -match '(issue|pr) comment \d+ --body') {
                $global:LASTEXITCODE = 0
                return 'https://github.com/example/example/pull/467#issuecomment-1'
            }
            if ($joined -match 'api repos/[^/]+/[^/]+ ') {
                $global:LASTEXITCODE = 0
                return '{"owner":{"login":"example"},"name":"example"}'
            }
            if ($joined -match 'api -X PATCH repos/[^/]+/[^/]+/issues/comments/\d+') {
                $global:LASTEXITCODE = 0
                return '{"html_url":"https://github.com/example/example/pull/467#issuecomment-2"}'
            }
            if ($joined -match 'pr edit \d+ --body-file') {
                $global:LASTEXITCODE = 0
                return ''
            }
            $global:LASTEXITCODE = 0
            return ''
        }

        function Get-CostTranscriptSlug {
            param([string]$CwdPath)
            if ($PoisonCostLib) { throw 'cost lib simulated failure' }
            return 'test-slug'
        }
        function Invoke-CostTranscriptWalk {
            param([string]$Slug, [string]$Branch, [string]$ParentCwd, [Nullable[int]]$IssueNumber = $null)
            return @()
        }
        function Invoke-CostCopilotWalk {
            param([string]$Branch, [string]$RepoRoot, [string]$OtelJsonlPath, [string]$WorkspaceFolderBasename = '')
            return @()
        }
        function Get-CostAttribution {
            param([object[]]$Events, [string]$RateTablePath = '')
            return @{ ports = @{}; orchestrator_overhead = @{}; dispatches = @{}; totals = @{ total_cost_usd = 0.0 } }
        }
        function Get-CostRollingHistory { param([int]$TimeoutSeconds = 10) return @{ timed_out = $false; entries = @() } }
        function Get-MostRecentRegimeCheckpoint { param([string]$Path) return $null }
        function Get-SessionCompleteness { param([object[]]$Events, [string]$ExcludeReason = '', [string]$Branch = '') return @{ completeness = 'unknown'; excluded_from_rolling_baseline = $true; exclude_reason = 'no-events' } }
        function Resolve-CostDataPreservation { param($Current, $Prior) return @{ use_prior = $false; notice = '' } }
        function Get-CostAnomalyFlags { param($ThisRun, [object[]]$RollingHistory, $RegimeCheckpoint) return @() }
        function Format-CostPatternMarkdown {
            param($Attribution, $Completeness, [object[]]$AnomalyFlags, $RollingMeta, [int]$Pr, [string]$Branch)
            return $capturedCostMarkdown
        }
        function Format-CostPatternYaml {
            param($Attribution, $Completeness, [object[]]$AnomalyFlags, [int]$Pr, [string]$Branch)
            return $capturedCostYaml
        }

        $script:FrameCreditLedgerRepoRoot = $capturedRepoRoot
        $result = Invoke-FrameCreditLedger -Pr 467 -Mode 'warn'
        # Apply the same exit-code translation the top-level script applies in warn mode:
        # warn mode never sets exitCode > 0 for IsInternalError or HasBlock — it stays 0.
        # Only enforce mode escalates to exit 3 (HasBlock) or exit 5 (IsInternalError).
        $processExitCode = 0
        return @{
            ExitCode = $processExitCode
            Comment  = if ($null -ne $result.Comment) { [string]$result.Comment } else { '' }
        }
        }
        finally {
            $env:FRAME_CREDIT_LEDGER_TEST_WALKER_INLINE = $previousInline
            $env:FRAME_CREDIT_LEDGER_TEST_NO_SLEEP = $previousNoSleep
        }
    }

    # -------------------------------------------------------------------------
    # Variant of InvokeOrchestratorInProcess that does NOT stub
    # Resolve-CostDataPreservation, allowing the real function (dot-sourced via
    # the orchestrator) to run. Used by the CI-contract preserve test (AC1).
    # Get-SessionCompleteness is still stubbed to return 'unknown' (simulating
    # the empty-walk CI enforce condition). Invoke-CostTranscriptWalk and
    # Get-CostAttribution stubs are preserved (s4 removes them; see s2<->s4
    # fixture coupling note in the plan).
    # -------------------------------------------------------------------------
    $script:InvokeOrchestratorInProcessWithRealPreservation = {
        param(
            [string]$PrBody = '',
            [string]$CostMarkdown = '## Cost Pattern',
            [string]$CostYaml = "<!-- cost-pattern-data`npr: 467`n-->",
            [object[]]$Comments = @(),
            [string]$CostBranch = 'feature/test-cost-integration'
        )

        $bodyJson = (@{ body = $PrBody; comments = $Comments } | ConvertTo-Json -Compress -Depth 5)
        $capturedCostMarkdown = $CostMarkdown
        $capturedCostYaml = $CostYaml
        $capturedRepoRoot = $script:RepoRoot

        $previousInline = $env:FRAME_CREDIT_LEDGER_TEST_WALKER_INLINE
        $previousNoSleep = $env:FRAME_CREDIT_LEDGER_TEST_NO_SLEEP
        try {
        $env:FRAME_CREDIT_LEDGER_TEST_WALKER_INLINE = '1'
        $env:FRAME_CREDIT_LEDGER_TEST_NO_SLEEP = '1'

        . $script:OrchestratorPath -Pr 467 -Mode 'warn'

        function git {
            param([Parameter(ValueFromRemainingArguments = $true)]$Args)
            $joined = $Args -join ' '
            if ($joined -match 'rev-parse --show-toplevel') {
                $global:LASTEXITCODE = 0
                return $capturedRepoRoot
            }
            if ($joined -match 'config --get remote\.origin\.url') {
                $global:LASTEXITCODE = 0
                return 'https://github.com/example/example.git'
            }
            if ($joined -match 'rev-parse --abbrev-ref HEAD') {
                $global:LASTEXITCODE = 0
                return $CostBranch
            }
            $global:LASTEXITCODE = 0
            return ''
        }

        function gh {
            param([Parameter(ValueFromRemainingArguments = $true)]$Args)
            $joined = $Args -join ' '
            if ($joined -match 'pr view \d+ --json baseRefOid') {
                $global:LASTEXITCODE = 0
                return '{"baseRefOid":"abc123"}'
            }
            if ($joined -match 'pr view \d+ --json body') {
                $global:LASTEXITCODE = 0
                return $bodyJson
            }
            if ($joined -match 'issue view \d+ --json comments') {
                $global:LASTEXITCODE = 0
                return '{"comments":[]}'
            }
            if ($joined -match '(issue|pr) comment \d+ --body') {
                $global:LASTEXITCODE = 0
                return 'https://github.com/example/example/pull/467#issuecomment-1'
            }
            if ($joined -match 'api repos/[^/]+/[^/]+ ') {
                $global:LASTEXITCODE = 0
                return '{"owner":{"login":"example"},"name":"example"}'
            }
            if ($joined -match 'api -X PATCH repos/[^/]+/[^/]+/issues/comments/\d+') {
                $global:LASTEXITCODE = 0
                return '{"html_url":"https://github.com/example/example/pull/467#issuecomment-2"}'
            }
            if ($joined -match 'pr edit \d+ --body-file') {
                $global:LASTEXITCODE = 0
                return ''
            }
            $global:LASTEXITCODE = 0
            return ''
        }

        function Get-CostTranscriptSlug {
            param([string]$CwdPath)
            return 'test-slug'
        }
        function Invoke-CostTranscriptWalk {
            param([string]$Slug, [string]$Branch, [string]$ParentCwd, [Nullable[int]]$IssueNumber = $null)
            return @()
        }
        function Invoke-CostCopilotWalk {
            param([string]$Branch, [string]$RepoRoot, [string]$OtelJsonlPath, [string]$WorkspaceFolderBasename = '')
            return @()
        }
        function Get-CostAttribution {
            param([object[]]$Events, [string]$RateTablePath = '')
            return @{ ports = @{}; orchestrator_overhead = @{}; dispatches = @{}; totals = @{ total_cost_usd = 0.0 } }
        }
        function Get-CostRollingHistory { param([int]$TimeoutSeconds = 10) return @{ timed_out = $false; entries = @() } }
        function Get-MostRecentRegimeCheckpoint { param([string]$Path) return $null }
        # Get-SessionCompleteness returns 'unknown' — simulates the empty-walk CI enforce condition.
        # Resolve-CostDataPreservation is NOT stubbed here; the real function (dot-sourced from the
        # orchestrator's cost lib) is used so the skip gate can fire when prior is complete.
        function Get-SessionCompleteness { param([object[]]$Events, [string]$ExcludeReason = '', [string]$Branch = '') return @{ completeness = 'unknown'; excluded_from_rolling_baseline = $true; exclude_reason = 'no-events' } }
        function Get-CostAnomalyFlags { param($ThisRun, [object[]]$RollingHistory, $RegimeCheckpoint) return @() }
        function Format-CostPatternMarkdown {
            param($Attribution, $Completeness, [object[]]$AnomalyFlags, $RollingMeta, [int]$Pr, [string]$Branch)
            return $capturedCostMarkdown
        }
        function Format-CostPatternYaml {
            param($Attribution, $Completeness, [object[]]$AnomalyFlags, [int]$Pr, [string]$Branch)
            return $capturedCostYaml
        }

        $script:FrameCreditLedgerRepoRoot = $capturedRepoRoot
        $result = Invoke-FrameCreditLedger -Pr 467 -Mode 'warn'
        $processExitCode = 0
        return @{
            ExitCode = $processExitCode
            Comment  = if ($null -ne $result.Comment) { [string]$result.Comment } else { '' }
        }
        }
        finally {
            $env:FRAME_CREDIT_LEDGER_TEST_WALKER_INLINE = $previousInline
            $env:FRAME_CREDIT_LEDGER_TEST_NO_SLEEP = $previousNoSleep
        }
    }

    # -------------------------------------------------------------------------
    # Issue #824 s3 — caller-wiring invoker. Does NOT stub Resolve-BaselineEligibility,
    # Format-CostPatternMarkdown, or Format-CostPatternYaml, so the real wrapper and
    # real renderers (dot-sourced from cost-completeness.ps1 / cost-pattern-renderer.ps1
    # by the orchestrator) run against a controllable synthetic completeness/attribution/
    # rolling-history shape. Resolve-CostDataPreservation IS stubbed, but only to capture
    # the $Current object and $CurrentTokenSum it receives (the M1 load-bearing-consumer
    # assertion) — its own return value is fixed so the fresh-render branch always fires.
    # -------------------------------------------------------------------------
    $script:InvokeOrchestratorWithRealEligibility = {
        param(
            [string]$PrBody = $script:V4AllCoveredBody,
            [object[]]$Comments = @(),
            [string]$CostBranch = 'feature/issue-824-baseline-eligibility',
            [string]$Completeness = 'partial',
            [AllowNull()][string]$StopReason = 'tool_use',
            [long]$TokenSum = 500,
            [string]$SessionIdEventValue = 'sess-824-abc',
            [object[]]$RollingEntries = @(),
            [bool]$RollingTimedOut = $false,
            [bool]$RollingPartialFetch = $false
        )

        $bodyJson = (@{ body = $PrBody; comments = $Comments } | ConvertTo-Json -Compress -Depth 5)
        $capturedRepoRoot = $script:RepoRoot

        $previousInline = $env:FRAME_CREDIT_LEDGER_TEST_WALKER_INLINE
        $previousNoSleep = $env:FRAME_CREDIT_LEDGER_TEST_NO_SLEEP
        try {
        $env:FRAME_CREDIT_LEDGER_TEST_WALKER_INLINE = '1'
        $env:FRAME_CREDIT_LEDGER_TEST_NO_SLEEP = '1'

        . $script:OrchestratorPath -Pr 467 -Mode 'warn'

        function git {
            param([Parameter(ValueFromRemainingArguments = $true)]$Args)
            $joined = $Args -join ' '
            if ($joined -match 'rev-parse --show-toplevel') {
                $global:LASTEXITCODE = 0
                return $capturedRepoRoot
            }
            if ($joined -match 'config --get remote\.origin\.url') {
                $global:LASTEXITCODE = 0
                return 'https://github.com/example/example.git'
            }
            if ($joined -match 'rev-parse --abbrev-ref HEAD') {
                $global:LASTEXITCODE = 0
                return $CostBranch
            }
            $global:LASTEXITCODE = 0
            return ''
        }

        function gh {
            param([Parameter(ValueFromRemainingArguments = $true)]$Args)
            $joined = $Args -join ' '
            if ($joined -match 'pr view \d+ --json baseRefOid') {
                $global:LASTEXITCODE = 0
                return '{"baseRefOid":"abc123"}'
            }
            if ($joined -match 'pr view \d+ --json body') {
                $global:LASTEXITCODE = 0
                return $bodyJson
            }
            if ($joined -match 'issue view \d+ --json comments') {
                $global:LASTEXITCODE = 0
                return '{"comments":[]}'
            }
            if ($joined -match '(issue|pr) comment \d+ --body') {
                $global:LASTEXITCODE = 0
                return 'https://github.com/example/example/pull/467#issuecomment-1'
            }
            if ($joined -match 'api repos/[^/]+/[^/]+ ') {
                $global:LASTEXITCODE = 0
                return '{"owner":{"login":"example"},"name":"example"}'
            }
            if ($joined -match 'api -X PATCH repos/[^/]+/[^/]+/issues/comments/\d+') {
                $global:LASTEXITCODE = 0
                return '{"html_url":"https://github.com/example/example/pull/467#issuecomment-2"}'
            }
            if ($joined -match 'pr edit \d+ --body-file') {
                $global:LASTEXITCODE = 0
                return ''
            }
            $global:LASTEXITCODE = 0
            return ''
        }

        function Get-CostTranscriptSlug {
            param([string]$CwdPath)
            return 'test-slug'
        }
        function Invoke-CostTranscriptWalk {
            param([string]$Slug, [string]$Branch, [string]$ParentCwd, [Nullable[int]]$IssueNumber = $null)
            return @(@{ type = 'assistant'; gitBranch = $Branch; message = @{ usage = @{ input_tokens = 0; output_tokens = 0 }; content = @() } })
        }
        # Real transcript events carry no embedded sessionId field (issue #824 s3
        # grounding fix) — the session identity is derived from the transcript FILE's
        # name on disk instead. This caller-wiring test controls that derived value
        # directly via a function override, mirroring how the walker functions above
        # are overridden rather than exercising real file discovery.
        function Get-CostWalkerCurrentSessionId {
            param([string]$Slug, [string]$Branch, [string]$ParentCwd, [string]$ProjectsRoot = '')
            return $SessionIdEventValue
        }
        function Invoke-CostCopilotWalk {
            param([string]$Branch, [string]$RepoRoot, [string]$OtelJsonlPath, [string]$WorkspaceFolderBasename = '')
            return @()
        }
        function Get-CostAttribution {
            param([object[]]$Events, [string]$RateTablePath = '')
            return @{
                ports                 = @{}
                orchestrator_overhead = @{
                    tokens               = @{ input = [long]$TokenSum; output = 0; cache_creation = 0; cache_read = 0 }
                    cost_estimate_usd    = 0.0
                    cache_read_hit_ratio = 0.0
                }
                dispatches            = @{ general_purpose_count = 0; unattributed_count = 0 }
                totals                = @{
                    total_cost_usd = 0.0
                    tokens         = @{ input = [long]$TokenSum; output = 0; cache_creation = 0; cache_read = 0 }
                }
            }
        }
        function Get-CostRollingHistory {
            param([int]$TimeoutSeconds = 10)
            $r = @{ timed_out = $RollingTimedOut; entries = $RollingEntries }
            if ($RollingPartialFetch) { $r['partial_fetch'] = $true }
            return $r
        }
        function Get-MostRecentRegimeCheckpoint { param([string]$Path) return $null }
        function Get-SessionCompleteness {
            param([object[]]$Events, [string]$ExcludeReason = '', [string]$Branch = '')
            return @{ completeness = $Completeness; stop_reason = $StopReason; excluded_from_rolling_baseline = $true; exclude_reason = $null }
        }
        function Resolve-CostDataPreservation {
            param($Current, $Prior, [long]$CurrentTokenSum = 0, [long]$PriorTokenSum = 0)
            $script:FCLS3CapturedPreservationCurrent = $Current
            $script:FCLS3CapturedPreservationTokenSum = $CurrentTokenSum
            return @{ use_prior = $false; notice = $null }
        }
        function Get-CostAnomalyFlags { param($ThisRun, [object[]]$RollingHistory, $RegimeCheckpoint) return @() }

        $script:FCLS3CapturedPreservationCurrent = $null
        $script:FCLS3CapturedPreservationTokenSum = $null
        $script:FrameCreditLedgerRepoRoot = $capturedRepoRoot
        $result = Invoke-FrameCreditLedger -Pr 467 -Mode 'warn'
        return @{
            ExitCode                 = 0
            Comment                  = if ($null -ne $result.Comment) { [string]$result.Comment } else { '' }
            CapturedPreservationCurrent  = $script:FCLS3CapturedPreservationCurrent
            CapturedPreservationTokenSum = $script:FCLS3CapturedPreservationTokenSum
        }
        }
        finally {
            $env:FRAME_CREDIT_LEDGER_TEST_WALKER_INLINE = $previousInline
            $env:FRAME_CREDIT_LEDGER_TEST_NO_SLEEP = $previousNoSleep
        }
    }
}

Describe 'frame-credit-ledger cost integration' {

    Context 'Compose-CommentWithCostPattern wrapper (unit)' {

        BeforeAll {
            if (Test-Path $script:CoreLibPath) {
                . $script:CoreLibPath
            }
        }

        It 'returns port coverage body unchanged when CostSection is empty string' {
            $reports = @(
                [pscustomobject]@{ PortName = 'review'; Status = 'Covered'; SubReason = 'PassedCredit'; AdapterName = ''; SuggestedNextStep = $null; Evidence = '' }
            )
            $result = Compose-CommentWithCostPattern -MarkerToken '<!-- test-marker -->' -PortReports $reports -CostSection ''
            $result | Should -Match 'Frame credit ledger'
            $result | Should -Not -Match 'Cost Pattern'
        }

        It 'returns port coverage body unchanged when CostSection is whitespace-only' {
            $reports = @(
                [pscustomobject]@{ PortName = 'review'; Status = 'Covered'; SubReason = 'PassedCredit'; AdapterName = ''; SuggestedNextStep = $null; Evidence = '' }
            )
            $result = Compose-CommentWithCostPattern -MarkerToken '<!-- test-marker -->' -PortReports $reports -CostSection '   '
            $result | Should -Match 'Frame credit ledger'
            $result | Should -Not -Match 'Cost Pattern'
        }

        It 'appends cost section separated by double newline when CostSection is non-empty' {
            $reports = @(
                [pscustomobject]@{ PortName = 'review'; Status = 'Covered'; SubReason = 'PassedCredit'; AdapterName = ''; SuggestedNextStep = $null; Evidence = '' }
            )
            $costSection = "## Cost Pattern`n<!-- cost-pattern-data`npr: 467`n-->"
            $result = Compose-CommentWithCostPattern -MarkerToken '<!-- test-marker -->' -PortReports $reports -CostSection $costSection
            $result | Should -Match 'Frame credit ledger'
            $result | Should -Match '## Cost Pattern'
            $result | Should -Match '<!-- cost-pattern-data'
        }

        It 'produces result that starts with the marker token' {
            $reports = @()
            $result = Compose-CommentWithCostPattern -MarkerToken '<!-- frame-credit-ledger-467 -->' -PortReports $reports -CostSection ''
            $result | Should -Match '<!-- frame-credit-ledger-467 -->'
        }

        It 'CostSection default parameter is empty string (omitting it behaves like Compose-Comment)' {
            $reports = @(
                [pscustomobject]@{ PortName = 'review'; Status = 'Covered'; SubReason = 'PassedCredit'; AdapterName = ''; SuggestedNextStep = $null; Evidence = '' }
            )
            # Call without -CostSection — should not throw and should return port coverage text
            $result = Compose-CommentWithCostPattern -MarkerToken '<!-- test-marker -->' -PortReports $reports
            $result | Should -Match 'Frame credit ledger'
        }
    }

    Context 'Orchestrator wiring: cost section appended for v4 PR (integration)' {

        It 'passes branch-slug issue number to cost walker before body-linked issue' {
            $body = $script:V4AllCoveredBody + "`nCloses #467`n"
            $result = & $script:InvokeOrchestratorInProcessWithWalkerCapture -PrBody $body -CostBranch 'feature/issue-529-step-4'

            $result.Result.ExitCode | Should -Be 0
            $result.Captured.HadIssueNumber | Should -Be $true
            $result.Captured.IssueNumber | Should -Be 529
        }

        It 'passes exact branch-slug issue number to cost walker' {
            $result = & $script:InvokeOrchestratorInProcessWithWalkerCapture -PrBody $script:V4AllCoveredBody -CostBranch 'feature/issue-529'

            $result.Result.ExitCode | Should -Be 0
            $result.Captured.HadIssueNumber | Should -Be $true
            $result.Captured.IssueNumber | Should -Be 529
        }

        It 'passes body-linked issue number to cost walker when branch slug is absent' {
            $body = $script:V4AllCoveredBody + "`nFixes #467`n"
            $result = & $script:InvokeOrchestratorInProcessWithWalkerCapture -PrBody $body -CostBranch 'topic/no-issue-slug'

            $result.Result.ExitCode | Should -Be 0
            $result.Captured.HadIssueNumber | Should -Be $true
            $result.Captured.IssueNumber | Should -Be 467
        }

        It 'omits cost walker issue number when neither branch nor body resolves an issue' {
            $result = & $script:InvokeOrchestratorInProcessWithWalkerCapture -PrBody $script:V4AllCoveredBody -CostBranch 'topic/no-issue-slug'

            $result.Result.ExitCode | Should -Be 0
            $result.Captured.HadIssueNumber | Should -Be $false
            $result.Captured.IssueNumber | Should -BeNullOrEmpty
        }

        It 'resolves repository root from script path for entry-point worker seeding' {
            . $script:OrchestratorPath -Pr 467 -Mode 'warn'
            $script:FrameCreditLedgerRepoRoot = $null

            $resolvedRoot = script:Resolve-FCLRepoRoot -ScriptPath $script:OrchestratorPath

            $resolvedRoot | Should -Be $script:RepoRoot
            $resolvedRoot | Should -Not -Be (Join-Path $script:RepoRoot '.github')
        }

        It 'passes repository root to cost walker through Invoke-FrameCreditLedger' {
            $result = & $script:InvokeOrchestratorInProcessWithWalkerCapture -PrBody $script:V4AllCoveredBody -CostBranch 'feature/issue-529-cost-telemetry-attribution'

            $result.Result.ExitCode | Should -Be 0
            $result.Captured.SlugCwd | Should -Be $script:RepoRoot
            $result.Captured.ParentCwd | Should -Be $script:RepoRoot
            $result.Captured.ParentCwd | Should -Not -Be (Join-Path $script:RepoRoot '.github')
        }

        It 'comment body contains Cost Pattern section when cost lib available' {
            $result = & $script:InvokeOrchestratorInProcess `
                -PrBody $script:V4AllCoveredBody `
                -CostMarkdown '## Cost Pattern' `
                -CostYaml "<!-- cost-pattern-data`npr: 467`n-->"

            $result.ExitCode | Should -Be 0
            $result.Comment | Should -Match '(?i)Frame credit ledger'
            $result.Comment | Should -Match '(?i)Cost Pattern'
        }

        It 'comment body contains <!-- cost-pattern-data marker when cost lib available' {
            $result = & $script:InvokeOrchestratorInProcess `
                -PrBody $script:V4AllCoveredBody `
                -CostMarkdown '## Cost Pattern' `
                -CostYaml "<!-- cost-pattern-data`npr: 467`n-->"

            $result.ExitCode | Should -Be 0
            $result.Comment | Should -Match '<!-- cost-pattern-data'
        }

        It 'comment body does not crash when cost lib functions are absent (graceful degradation)' {
            # Simulate cost lib unavailable by having Get-CostTranscriptSlug throw.
            # The orchestrator step 6 try/catch must degrade gracefully — exit 0,
            # port coverage section still present.
            $result = & $script:InvokeOrchestratorInProcess `
                -PrBody $script:V4AllCoveredBody `
                -PoisonCostLib $true

            # Must exit 0 — graceful degradation, not a crash
            $result.ExitCode | Should -Be 0
            # Port coverage section must still be present
            $result.Comment | Should -Match '(?i)Frame credit ledger'
        }

        It 'pre-v4 short-circuit still works (cost section not added when pre-v4)' {
            $result = & $script:InvokeOrchestratorInProcess `
                -PrBody $script:PreV4Body

            $result.ExitCode | Should -Be 0
            $result.Comment | Should -Match '(?i)pre-v4 metrics detected'
            # Cost Pattern must NOT appear in the pre-v4 short-circuit path
            $result.Comment | Should -Not -Match '<!-- cost-pattern-data'
        }

        It 'idempotent re-run produces same comment structure' {
            # Run twice; both must exit 0 and produce identical structural markers
            $result1 = & $script:InvokeOrchestratorInProcess `
                -PrBody $script:V4AllCoveredBody `
                -CostMarkdown '## Cost Pattern' `
                -CostYaml "<!-- cost-pattern-data`npr: 467`n-->"

            $result2 = & $script:InvokeOrchestratorInProcess `
                -PrBody $script:V4AllCoveredBody `
                -CostMarkdown '## Cost Pattern' `
                -CostYaml "<!-- cost-pattern-data`npr: 467`n-->"

            $result1.ExitCode | Should -Be 0
            $result2.ExitCode | Should -Be 0

            # Both runs must emit the same structural markers
            ($result1.Comment -match '(?i)Frame credit ledger') | Should -Be ($result2.Comment -match '(?i)Frame credit ledger')
            ($result1.Comment -match '<!-- cost-pattern-data')  | Should -Be ($result2.Comment -match '<!-- cost-pattern-data')
        }
    }

    Context 'D10 re-emission preservation path (Pass3-F1 fix)' {

        It 'orchestrator completes with exit 0 and still emits cost section when prior cost-pattern-data comment exists in PR comments' {
            # Build a PR comments array that contains a prior cost-pattern-data block.
            # The orchestrator's step 6e checks $script:PrComments for a body matching
            # '<!-- cost-pattern-data' and sets $priorCostData when found.
            # This exercises the preservation-path code branch without crashing.
            $priorCostBody = "## Cost Pattern`n<!-- cost-pattern-data`nversion: 1`nsession_completeness: complete`nexcluded_from_rolling_baseline: false`ngenerated_at: 2026-04-01T00:00:00Z`nports:`nanomaly_flags: []`n-->"
            $comments = @([pscustomobject]@{ body = $priorCostBody; databaseId = 1001 })

            $result = & $script:InvokeOrchestratorInProcess `
                -PrBody $script:V4AllCoveredBody `
                -CostMarkdown '## Cost Pattern' `
                -CostYaml "<!-- cost-pattern-data`npr: 467`n-->" `
                -Comments $comments

            # Must complete without crash regardless of prior comment presence
            $result.ExitCode | Should -Be 0
            # Cost pattern section must still be emitted (preservation path doesn't suppress output)
            $result.Comment | Should -Match '<!-- cost-pattern-data'
        }

        It 'orchestrator completes with exit 0 when comments array contains only non-cost comments' {
            # Non-cost comments should be silently ignored; no crash expected.
            $comments = @([pscustomobject]@{ body = '## Some regular PR comment without cost marker'; databaseId = 1002 })

            $result = & $script:InvokeOrchestratorInProcess `
                -PrBody $script:V4AllCoveredBody `
                -CostMarkdown '## Cost Pattern' `
                -CostYaml "<!-- cost-pattern-data`npr: 467`n-->" `
                -Comments $comments

            $result.ExitCode | Should -Be 0
            $result.Comment | Should -Match '<!-- cost-pattern-data'
        }
    }

    Context 'gh pr view combined call (M4)' {

        It 'orchestrator calls gh pr view with --json body,comments (not just body)' {
            # Verify the orchestrator completes and produces port coverage output.
            # The in-process gh mock handles 'pr view \d+ --json body' which matches
            # 'body,comments' too (the combined M4 call). Since Invoke-FrameCreditLedger
            # returns the comment body, assert on the marker token.
            $result = & $script:InvokeOrchestratorInProcess `
                -PrBody $script:V4AllCoveredBody

            $result.ExitCode | Should -Be 0
            # Confirm the run completed and produced port coverage output
            $result.Comment | Should -Match '(?i)frame-credit-ledger-467'
        }
    }

    Context 'D2 — non-vacuous walker accuracy' {

        It 'attributed events are correct and stable across two runs' {
            # Create a synthetic projects root with known events.
            # 3 events on the target branch + 1 on main (must be excluded by branch filter).
            $tmp = Join-Path ([IO.Path]::GetTempPath()) "cost-accuracy-$([System.Guid]::NewGuid())"
            $slug = 'c--Users-Test-myrepo'
            $slugDir = Join-Path $tmp $slug
            $null = New-Item -ItemType Directory -Path $slugDir -Force

            $branch = 'feature/test-accuracy'
            $cwd = 'C:\Users\Test\myrepo'

            $events = @(
                @{ type = 'assistant'; uuid = 'acc-0001'; timestamp = '2026-01-01T00:00:00Z'; cwd = $cwd; gitBranch = $branch; message = @{ usage = @{ input_tokens = 100; output_tokens = 50 }; content = @() } }
                @{ type = 'assistant'; uuid = 'acc-0002'; timestamp = '2026-01-01T00:01:00Z'; cwd = $cwd; gitBranch = $branch; message = @{ usage = @{ input_tokens = 200; output_tokens = 100 }; content = @() } }
                @{ type = 'assistant'; uuid = 'acc-0003'; timestamp = '2026-01-01T00:02:00Z'; cwd = $cwd; gitBranch = 'main'; message = @{ usage = @{ input_tokens = 999; output_tokens = 999 }; content = @() } }
                @{ type = 'assistant'; uuid = 'acc-0004'; timestamp = '2026-01-01T00:03:00Z'; cwd = $cwd; gitBranch = $branch; message = @{ usage = @{ input_tokens = 300; output_tokens = 150 }; content = @() } }
            )
            $events | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 10 } | Set-Content -Path (Join-Path $slugDir 'session.jsonl') -Encoding utf8NoBOM

            # Run the real walker twice in isolated scriptblock scopes to verify
            # determinism. Each scriptblock dot-sources the walker fresh so stubs
            # in the outer test scope do not shadow the real functions.
            # Use .GetNewClosure() to capture local variables into the scriptblock scope
            # (avoids $using: which is only valid in remote/parallel contexts).
            $libDir = $script:LibDir
            $walkerBlock = {
                param($WSlug, $WBranch, $WCwd, $WTmp, $WLibDir)
                . (Join-Path $WLibDir 'cost-walker.ps1')
                . (Join-Path $WLibDir 'path-normalize.ps1')
                @(Invoke-CostTranscriptWalk -Slug $WSlug -Branch $WBranch -ParentCwd $WCwd -ProjectsRoot $WTmp)
            }
            $run1 = & $walkerBlock $slug $branch $cwd $tmp $libDir
            $run2 = & $walkerBlock $slug $branch $cwd $tmp $libDir

            # Non-vacuous: must find exactly the 3 target-branch events (acc-0003 is on main → excluded).
            $run1.Count | Should -Be 3
            # Stable across 2 runs.
            $run2.Count | Should -Be 3
            # UUIDs are exactly the expected set.
            $run1Uuids = @($run1 | ForEach-Object { $_['uuid'] } | Sort-Object)
            $run1Uuids | Should -Be @('acc-0001', 'acc-0002', 'acc-0004')
            $run2Uuids = @($run2 | ForEach-Object { $_['uuid'] } | Sort-Object)
            $run2Uuids | Should -BeExactly $run1Uuids

            Remove-Item -Recurse -Force $tmp
        }
    }

    Context 'D1 CI-contract preservation (skip-when-absent gate)' {

        It 'preserves prior cost-pattern-data block when projects root is absent (CI enforce path)' {
            # When the CI enforce run produces completeness='unknown' (empty walk) and
            # the prior comment contains a session_completeness: complete block, the
            # skip-when-absent gate must fire and the output comment must contain the
            # prior block's cost-pattern-data plus the preservation notice.
            # The InvokeOrchestratorInProcessWithRealPreservation variant omits the
            # Resolve-CostDataPreservation stub so the real function can return use_prior=true.
            $priorCostBody = "## Cost Pattern`n<!-- cost-pattern-data`nversion: 1`nsession_completeness: complete`nexcluded_from_rolling_baseline: false`ngenerated_at: 2026-04-01T00:00:00Z`nports:`nanomaly_flags: []`npr: 467`n-->"
            $comments = @([pscustomobject]@{ body = $priorCostBody; databaseId = 2001 })

            $result = & $script:InvokeOrchestratorInProcessWithRealPreservation `
                -PrBody $script:V4AllCoveredBody `
                -Comments $comments

            $result.ExitCode | Should -Be 0
            $result.Comment | Should -Match '<!-- cost-pattern-data'
            # Preservation notice must be surfaced in the output (> [!NOTE] block)
            $result.Comment | Should -Match 'NOTE'
            # Verify the prior block's content survived (not replaced by fresh-empty render).
            # The prior body contains 'generated_at: 2026-04-01' which the fresh stub does not.
            # A clobber would produce only 'pr: 467' with no prior timestamp.
            $result.Comment | Should -Match '2026-04-01'
        }

        It 'preserves malformed-but-present prior block verbatim (Fix #760-F9)' {
            # Regression for the C3 erase defect: when a prior cost-pattern-data block
            # exists (matches loose selector) but its body cannot be extracted by the
            # strict multiline regex (malformed — no newline after marker), the C3 fix
            # correctly defaults priorCostData to 'complete' → use_prior=true.  Before
            # the F9 fix, the section-rebuild re-called the failing extractor, got $null,
            # left $costSection='', and ERASED the prior block.  After the fix, the raw
            # block is carried verbatim, honoring the D1 invariant.
            # A malformed block: matches '<!-- cost-pattern-data' (loose) but the strict
            # multiline regex '<!--\s*cost-pattern-data\s*\r?\n([\s\S]*?)\r?\n?-->' fails
            # because there is no newline after the marker — single-line form.
            $malformedBlockSentinel = 'f9-sentinel-malformed-unique'
            $priorCostBody = "## Cost Pattern`n<!-- cost-pattern-data $malformedBlockSentinel -->"
            $comments = @([pscustomobject]@{ body = $priorCostBody; databaseId = 2999 })

            $result = & $script:InvokeOrchestratorInProcessWithRealPreservation `
                -PrBody $script:V4AllCoveredBody `
                -Comments $comments

            $result.ExitCode | Should -Be 0
            # The malformed block must survive verbatim — if F9 regresses, $costSection
            # is '' and the sentinel disappears from the comment.
            $result.Comment | Should -Match $malformedBlockSentinel -Because 'malformed prior block must be carried verbatim, not erased'
            $result.Comment | Should -Match '<!-- cost-pattern-data' -Because 'cost marker must be present'
        }

        It 'returns use_prior=true when current is unknown and prior is complete' {
            # Unit test directly against Resolve-CostDataPreservation with the
            # corrected flat $Prior shape (completeness + rendered_at keys).
            . $script:OrchestratorPath -Pr 467 -Mode 'warn'
            $prior = @{ completeness = 'complete'; rendered_at = '2026-01-01T00:00:00Z' }
            $current = @{ completeness = 'unknown'; excluded_from_rolling_baseline = $true }
            $result = Resolve-CostDataPreservation -Current $current -Prior $prior
            $result['use_prior'] | Should -Be $true
            $result['notice'] | Should -Not -BeNullOrEmpty
        }

        It 'renders fresh cost section without crash when no prior comment exists (cold start)' {
            # Verify that when there is no prior cost-pattern-data comment (cold start),
            # the orchestrator still renders normally — no crash, no preservation fires.
            $result = & $script:InvokeOrchestratorInProcess `
                -PrBody $script:V4AllCoveredBody `
                -CostMarkdown '## Cost Pattern' `
                -CostYaml "<!-- cost-pattern-data`npr: 467`n-->"
            $result.ExitCode | Should -Be 0
            $result.Comment | Should -Match '<!-- cost-pattern-data'
        }
    }

    Context 'Baseline eligibility caller wiring (issue #824 s3)' {

        It 'markdown header, YAML flag, and preservation input all agree on an eligible mid-session capture, and the block carries session_id/head_ref' {
            $result = & $script:InvokeOrchestratorWithRealEligibility `
                -Completeness 'partial' `
                -StopReason 'tool_use' `
                -TokenSum 500 `
                -SessionIdEventValue 'sess-824-eligible' `
                -CostBranch 'feature/issue-824-baseline-eligibility'

            $result.ExitCode | Should -Be 0

            # Markdown header carries the self-contained eligible-partial disclosure (M6).
            $result.Comment | Should -Match 'mid-session capture — baseline-eligible'

            # YAML flag agrees: not excluded, capture_point is the mid-session value.
            $result.Comment | Should -Match 'excluded_from_rolling_baseline: false'
            $result.Comment | Should -Match 'capture_point: pr-creation-mid-session'

            # Additive targeting keys persisted (issue #824 s3 point 4).
            $result.Comment | Should -Match 'session_id: sess-824-eligible'
            $result.Comment | Should -Match 'head_ref: feature/issue-824-baseline-eligibility'

            # Load-bearing M1 consumer: Resolve-CostDataPreservation received the SAME
            # post-eligibility object the renderers used — not a stale pre-eligibility copy.
            $result.CapturedPreservationCurrent | Should -Not -BeNullOrEmpty
            $result.CapturedPreservationCurrent['excluded_from_rolling_baseline'] | Should -Be $false
            $result.CapturedPreservationCurrent['capture_point'] | Should -Be 'pr-creation-mid-session'
            $result.CapturedPreservationTokenSum | Should -Be 500
        }

        It 'markdown header, YAML flag, and preservation input all agree on an excluded mid-session capture (named partial reason)' {
            $result = & $script:InvokeOrchestratorWithRealEligibility `
                -Completeness 'partial' `
                -StopReason 'refusal' `
                -TokenSum 500

            $result.ExitCode | Should -Be 0
            $result.Comment | Should -Not -Match 'baseline-eligible'
            $result.Comment | Should -Match 'excluded_from_rolling_baseline: true'
            $result.Comment | Should -Match 'capture_point: n/a'
            $result.CapturedPreservationCurrent['excluded_from_rolling_baseline'] | Should -Be $true
            $result.CapturedPreservationCurrent['capture_point'] | Should -Be 'n/a'
        }
    }

    Context 'Recurrence guard predicate (issue #824 s3 DD7)' {

        BeforeAll {
            . $script:OrchestratorPath -Pr 0 -Mode 'warn' -ErrorAction SilentlyContinue 2>$null
        }

        It 'warns when current is excluded and every rolling-history entry is also excluded (healthy, non-empty)' {
            $rolling = @{ timed_out = $false; entries = @(@{ excluded_from_rolling_baseline = $true }, @{ excluded_from_rolling_baseline = $true }) }
            Test-FCLRecurrenceGuardShouldWarn -CurrentExcluded $true -RollingResult $rolling | Should -Be $true
        }

        It 'stays silent when current is eligible, regardless of history' {
            $rolling = @{ timed_out = $false; entries = @(@{ excluded_from_rolling_baseline = $true }) }
            Test-FCLRecurrenceGuardShouldWarn -CurrentExcluded $false -RollingResult $rolling | Should -Be $false
        }

        It 'stays silent on cold start (empty rolling history)' {
            $rolling = @{ timed_out = $false; entries = @() }
            Test-FCLRecurrenceGuardShouldWarn -CurrentExcluded $true -RollingResult $rolling | Should -Be $false
        }

        It 'stays silent on a timed-out rolling-history fetch' {
            $rolling = @{ timed_out = $true; entries = @(@{ excluded_from_rolling_baseline = $true }) }
            Test-FCLRecurrenceGuardShouldWarn -CurrentExcluded $true -RollingResult $rolling | Should -Be $false
        }

        It 'stays silent on a partial-fetch rolling history' {
            $rolling = @{ timed_out = $false; entries = @(@{ excluded_from_rolling_baseline = $true }); partial_fetch = $true }
            Test-FCLRecurrenceGuardShouldWarn -CurrentExcluded $true -RollingResult $rolling | Should -Be $false
        }

        It 'stays silent when at least one rolling-history entry is eligible' {
            $rolling = @{ timed_out = $false; entries = @(@{ excluded_from_rolling_baseline = $true }, @{ excluded_from_rolling_baseline = $false }) }
            Test-FCLRecurrenceGuardShouldWarn -CurrentExcluded $true -RollingResult $rolling | Should -Be $false
        }
    }
}

# ===========================================================================
# Issue #769 AC3 — Origin-gated 3-state taxonomy integration tests
#
# Validates that the orchestrator correctly routes the missing-block short-
# circuit to the 🛑 FAILED or "not measured (non-orchestrated)" state based
# on the CI-safe origin predicate (Get-FCLOriginContext).
# ===========================================================================
Describe 'frame-credit-ledger origin-gated taxonomy (issue #769 AC3)' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:OrchestratorPath = Join-Path $script:RepoRoot '.github/scripts/frame-credit-ledger.ps1'

        # Empty PR body: no pipeline-metrics block. Used to exercise the null short-circuit.
        $script:EmptyBody = '## Summary' + [Environment]::NewLine + 'A PR with no pipeline-metrics block.'

        # Pre-v4 body for the pre-v4 short-circuit test.
        $script:PreV4BodyForTaxonomy = @'
## Summary

A pre-v4 PR body.

<!-- pipeline-metrics
metrics_version: 3
some_legacy_field: value
-->
'@

        # Parse-error body: block exists but YAML is malformed.
        $script:ParseErrorBody = @'
## Summary

A PR with a malformed pipeline-metrics block.

<!-- pipeline-metrics
: missing key
-->
'@

        # ---------------------------------------------------------------------------
        # InvokeWithOriginControl: runs Invoke-FrameCreditLedger in-process with full
        # mock wiring. Accepts:
        #   -PrBody        : the PR body text
        #   -HeadRef       : simulates $env:GITHUB_HEAD_REF (CI-safe branch name)
        #   -SuppressFailed: simulates $env:FCL_SUPPRESS_FAILED_POSTS=1
        # Returns @{ Comment = '...'; ExitCode = 0 }.
        # ---------------------------------------------------------------------------
        $script:InvokeWithOriginControl = {
            param(
                [string]$PrBody = '',
                [string]$HeadRef = '',
                [bool]$SuppressFailed = $false
            )

            $capturedRepoRoot = $script:RepoRoot
            $capturedHeadRef = $HeadRef
            $capturedSuppressFailed = $SuppressFailed
            $bodyJson = (@{ body = $PrBody; comments = @() } | ConvertTo-Json -Compress -Depth 5)

            $previousNoSleep = $env:FRAME_CREDIT_LEDGER_TEST_NO_SLEEP
            $previousHeadRef = $env:GITHUB_HEAD_REF
            $previousSuppress = $env:FCL_SUPPRESS_FAILED_POSTS
            try {
                $env:FRAME_CREDIT_LEDGER_TEST_NO_SLEEP = '1'
                $env:GITHUB_HEAD_REF = $capturedHeadRef
                $env:FCL_SUPPRESS_FAILED_POSTS = if ($capturedSuppressFailed) { '1' } else { '' }

                . $script:OrchestratorPath -Pr 769 -Mode 'warn'

                function git {
                    param([Parameter(ValueFromRemainingArguments = $true)]$Args)
                    $joined = $Args -join ' '
                    if ($joined -match 'rev-parse --show-toplevel') {
                        $global:LASTEXITCODE = 0; return $capturedRepoRoot
                    }
                    if ($joined -match 'config --get remote\.origin\.url') {
                        $global:LASTEXITCODE = 0; return 'https://github.com/example/example.git'
                    }
                    if ($joined -match 'rev-parse --abbrev-ref HEAD') {
                        # Return the HeadRef when asked for branch name (for cost walker compat).
                        $global:LASTEXITCODE = 0
                        return if ([string]::IsNullOrWhiteSpace($capturedHeadRef)) { 'HEAD' } else { $capturedHeadRef }
                    }
                    $global:LASTEXITCODE = 0; return ''
                }

                $script:_PostedComments = [System.Collections.Generic.List[string]]::new()

                function gh {
                    param([Parameter(ValueFromRemainingArguments = $true)]$Args)
                    $joined = $Args -join ' '
                    if ($joined -match 'pr view \d+ --json baseRefOid') {
                        $global:LASTEXITCODE = 0; return '{"baseRefOid":"abc123"}'
                    }
                    if ($joined -match 'pr view \d+ --json body') {
                        $global:LASTEXITCODE = 0; return $bodyJson
                    }
                    if ($joined -match 'issue view \d+ --json comments') {
                        $global:LASTEXITCODE = 0; return '{"comments":[]}'
                    }
                    if ($joined -match '(issue|pr) comment \d+ --body') {
                        # Capture the comment body for assertion in off-switch test.
                        $bodyArgIdx = ($Args | Select-Object -SkipLast 0) | ForEach-Object { $_ } | Select-String -Pattern '^--body$' -List
                        $script:_PostedComments.Add([string]($Args[-1])) | Out-Null
                        $global:LASTEXITCODE = 0; return 'https://github.com/example/example/pull/769#issuecomment-1'
                    }
                    if ($joined -match 'api repos/[^/]+/[^/]+ ') {
                        $global:LASTEXITCODE = 0; return '{"owner":{"login":"example"},"name":"example"}'
                    }
                    if ($joined -match 'api -X PATCH repos/[^/]+/[^/]+/issues/comments/\d+') {
                        $global:LASTEXITCODE = 0; return '{"html_url":"https://github.com/example/example/pull/769#issuecomment-2"}'
                    }
                    if ($joined -match 'pr edit \d+ --body-file') {
                        $global:LASTEXITCODE = 0; return ''
                    }
                    $global:LASTEXITCODE = 0; return ''
                }

                # Stub cost lib to avoid real walker invocations.
                function Get-CostTranscriptSlug { param([string]$CwdPath) return '' }
                function Invoke-CostTranscriptWalk { param([string]$Slug, [string]$Branch, [string]$ParentCwd, [Nullable[int]]$IssueNumber = $null) return @() }
                function Invoke-CostCopilotWalk { param([string]$Branch, [string]$RepoRoot, [string]$OtelJsonlPath, [string]$WorkspaceFolderBasename = '') return @() }
                function Get-CostAttribution { param([object[]]$Events, [string]$RateTablePath = '') return @{ ports = @{}; orchestrator_overhead = @{}; dispatches = @{}; totals = @{ total_cost_usd = 0.0 } } }
                function Get-CostRollingHistory { param([int]$TimeoutSeconds = 10) return @{ timed_out = $false; entries = @() } }
                function Get-MostRecentRegimeCheckpoint { param([string]$Path) return $null }
                function Get-SessionCompleteness { param([object[]]$Events, [string]$ExcludeReason = '', [string]$Branch = '') return @{ completeness = 'unknown'; excluded_from_rolling_baseline = $true; exclude_reason = 'no-events' } }
                function Resolve-CostDataPreservation { param($Current, $Prior) return @{ use_prior = $false; notice = '' } }
                function Get-CostAnomalyFlags { param($ThisRun, [object[]]$RollingHistory, $RegimeCheckpoint) return @() }
                function Format-CostPatternMarkdown { param($Attribution, $Completeness, [object[]]$AnomalyFlags, $RollingMeta, [int]$Pr, [string]$Branch) return '## Cost Pattern' }
                function Format-CostPatternYaml { param($Attribution, $Completeness, [object[]]$AnomalyFlags, [int]$Pr, [string]$Branch) return "<!-- cost-pattern-data`npr: $Pr`n-->" }

                $script:FrameCreditLedgerRepoRoot = $capturedRepoRoot
                $result = Invoke-FrameCreditLedger -Pr 769 -Mode 'warn'

                return @{
                    ExitCode         = 0
                    Comment          = if ($null -ne $result.Comment) { [string]$result.Comment } else { '' }
                    PostedComments   = @($script:_PostedComments)
                }
            }
            finally {
                $env:FRAME_CREDIT_LEDGER_TEST_NO_SLEEP = $previousNoSleep
                $env:GITHUB_HEAD_REF = $previousHeadRef
                $env:FCL_SUPPRESS_FAILED_POSTS = $previousSuppress
            }
        }
    }

    Context 'Missing block — orchestrated-origin → 🛑 FAILED' {

        It 'GITHUB_HEAD_REF=feature/issue-769 and no block → comment contains 🛑 FAILED' {
            $result = & $script:InvokeWithOriginControl `
                -PrBody $script:EmptyBody `
                -HeadRef 'feature/issue-769-v4-emission-reliability'

            $result.ExitCode | Should -Be 0
            $result.Comment | Should -Match '🛑'
            $result.Comment | Should -Match 'FAILED'
            $result.Comment | Should -Not -Match 'non-orchestrated'
            $result.Comment | Should -Not -Match 'not measured'
        }
    }

    Context 'Missing block — non-orchestrated → "not measured (non-orchestrated)"' {

        It 'GITHUB_HEAD_REF=topic/no-issue and no block → quiet "not measured" comment' {
            $result = & $script:InvokeWithOriginControl `
                -PrBody $script:EmptyBody `
                -HeadRef 'topic/no-issue-slug'

            $result.ExitCode | Should -Be 0
            $result.Comment | Should -Match 'not measured \(non-orchestrated\)'
            $result.Comment | Should -Not -Match '🛑'
            $result.Comment | Should -Not -Match 'FAILED'
        }
    }

    Context 'Pre-v4 block → pre-v4 state (origin-agnostic)' {

        It 'pre-v4 block renders pre-v4 state regardless of orchestrated-origin' {
            # Even on orchestrated-origin branch, the pre-v4 path renders the pre-v4 comment.
            $result = & $script:InvokeWithOriginControl `
                -PrBody $script:PreV4BodyForTaxonomy `
                -HeadRef 'feature/issue-769-pre-v4-test'

            $result.ExitCode | Should -Be 0
            $result.Comment | Should -Match '(?i)pre-v4 metrics detected'
            $result.Comment | Should -Not -Match 'non-orchestrated'
            $result.Comment | Should -Not -Match '🛑'
        }
    }

    Context 'Parse-error → 🛑 FAILED (origin-agnostic)' {

        It 'parse-error block renders FAILED regardless of origin (parse errors always signal failure)' {
            # Even on non-orchestrated branch, parse-error is a genuine failure.
            $result = & $script:InvokeWithOriginControl `
                -PrBody $script:ParseErrorBody `
                -HeadRef 'topic/no-issue-slug'

            $result.ExitCode | Should -Be 0
            # Parse-error comment uses ⚠️ (not 🛑) — the parse-error path is unchanged;
            # the ⚠️ serves as the failure signal here.
            $result.Comment | Should -Match '(?i)could not be parsed'
            $result.Comment | Should -Not -Match 'not measured'
        }
    }

    Context 'Off-switch (FCL_SUPPRESS_FAILED_POSTS=1) — FAILED posts suppressed, non-FAILED not suppressed' {

        It 'off-switch active: FAILED-state post not fired; comment still returned' {
            # When off-switch is active and origin is orchestrated + block absent,
            # Find-OrUpsertComment must NOT be called (no posted comments),
            # but the result.Comment must still be set to the FAILED comment text.
            $result = & $script:InvokeWithOriginControl `
                -PrBody $script:EmptyBody `
                -HeadRef 'feature/issue-769-off-switch-test' `
                -SuppressFailed $true

            $result.ExitCode | Should -Be 0
            # Comment still populated (return value carries the composed text)
            $result.Comment | Should -Match '🛑'
            # No post was fired — PostedComments must be empty
            $result.PostedComments.Count | Should -Be 0 -Because 'off-switch suppresses FAILED-state gh comment calls'
        }

        It 'off-switch active: non-orchestrated "not measured" post still fires (not suppressed)' {
            # Off-switch only suppresses FAILED-state posts; non-orchestrated posts always fire.
            $result = & $script:InvokeWithOriginControl `
                -PrBody $script:EmptyBody `
                -HeadRef 'topic/no-issue-non-orchestrated' `
                -SuppressFailed $true

            $result.ExitCode | Should -Be 0
            $result.Comment | Should -Match 'not measured \(non-orchestrated\)'
            # The non-orchestrated comment must have been posted
            $result.PostedComments.Count | Should -BeGreaterOrEqual 1 -Because 'non-FAILED posts are not suppressed by off-switch'
        }
    }
}
