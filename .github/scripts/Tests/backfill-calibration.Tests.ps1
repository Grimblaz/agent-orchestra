#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
.SYNOPSIS
    Pester 5 tests for backfill-calibration.ps1.

.DESCRIPTION
    Contract under test:
      - Fetches merged PRs via `gh pr list --state merged --limit $Limit --json number,mergedAt,body`
      - For each PR: extracts the <!-- pipeline-metrics --> block from the body
      - Skips PRs with no <!-- pipeline-metrics --> block
      - Skips PRs whose metrics block has no `findings:` array (v1-only PRs)
      - For v2 PRs (have `findings:` array): builds an entry JSON with:
          - pr_number  ← PR number from API
          - created_at ← PR mergedAt from GitHub API
          - findings[] ← extracted from pipeline-metrics block
          - summary    ← extracted from pipeline-metrics top-level scalar fields
      - Writes entries in-process to .copilot-tracking/calibration/review-data.json
      - Accepts -GhCliPath to inject a mock gh binary (enables test isolation)
      - Exits 0 with informational message when gh returns an empty PR list
      - Exits non-zero when gh is unavailable or returns a non-zero exit code
      - Exits 0 on success

    Isolation strategy:
      - Each test creates a fresh temp directory via $script:NewWorkDir.
      - A minimal mock `gh.ps1` is written into the temp dir; its path is
        passed to the script via -GhCliPath so the real `gh` CLI is never
        invoked.
      - Tests read the output JSON directly to inspect entries written.
      - Invocations run in-process by calling Invoke-BackfillCalibration from
        lib/backfill-calibration-core.ps1 directly (no child pwsh spawning).
#>

Describe 'backfill-calibration.ps1' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:ScriptFile = Join-Path $script:RepoRoot '.github\skills\calibration-pipeline\scripts\backfill-calibration.ps1'
        $script:LibFile = Join-Path $script:RepoRoot '.github\skills\calibration-pipeline\scripts\backfill-calibration-core.ps1'
        . $script:LibFile

        # ---------------------------------------------------------------------------
        # Shared pipeline-metrics content used across tests
        # NOTE: Must be in BeforeAll — Pester 5 does not preserve top-level script
        # variables across the discovery→execution boundary.
        # ---------------------------------------------------------------------------

        # V2 metrics block body — has a `findings:` array
        $script:V2MetricsBody = @'
## PR Summary

Some PR text here.

<!-- pipeline-metrics
metrics_version: 2
prosecution_findings: 3
pass_1_findings: 1
pass_2_findings: 1
pass_3_findings: 1
defense_disproved: 1
judge_accepted: 2
judge_rejected: 0
judge_deferred: 1
ce_gate_result: passed
ce_gate_intent: strong
ce_gate_defects_found: 0
rework_cycles: 0
postfix_triggered: false
postfix_prosecution_findings: 0
postfix_judge_accepted: 0
postfix_judge_rejected: 0
postfix_judge_deferred: 0
postfix_defense_disproved: 0
postfix_rework_cycles: n/a
findings:
  - id: F1
    category: architecture
    severity: high
    points: 10
    pass: 1
    defense_verdict: conceded
    judge_ruling: sustained
    judge_confidence: high
    review_stage: main
-->
'@

        # V1 metrics block body — has pipeline-metrics but NO findings array
        $script:V1MetricsBody = @'
## PR Summary

Some PR text here.

<!-- pipeline-metrics
metrics_version: 1
prosecution_findings: 2
judge_accepted: 1
judge_rejected: 1
-->
'@

        # Body with no pipeline-metrics block at all
        $script:NoMetricsBody = @'
## PR Summary

This PR has no pipeline metrics block.

Just some regular description text.
'@

        # Master temp root — all per-test dirs live under here
        $script:TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "pester-backfill-$([System.Guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path $script:TempRoot -Force | Out-Null

        # ------------------------------------------------------------------
        # Helper: make a fresh isolated temp dir for a single test
        # ------------------------------------------------------------------
        $script:NewWorkDir = {
            $dir = Join-Path $script:TempRoot ([System.Guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            return $dir
        }

        # ------------------------------------------------------------------
        # Helper: write a mock gh.ps1 into a temp dir that outputs a given
        # JSON array when called with `pr list` arguments.
        # Returns the path to the mock script.
        # ------------------------------------------------------------------
        $script:WriteMockGh = {
            param(
                [string]$WorkDir,
                [string]$JsonOutput   # JSON array string the mock should emit
            )
            $mockPath = Join-Path $WorkDir 'gh.ps1'
            # Escape the JSON so it embeds cleanly in the here-string script body.
            # We write the JSON into a companion data file and cat it from there
            # to avoid quoting hazards inside the generated script.
            $dataFile = Join-Path $WorkDir 'gh-response.json'
            $JsonOutput | Set-Content -Path $dataFile -Encoding UTF8

            $mockScript = @"
# Mock gh CLI — outputs pre-defined JSON regardless of arguments
Get-Content -Raw -Path '$($dataFile -replace "'", "''")'
exit 0
"@
            $mockScript | Set-Content -Path $mockPath -Encoding UTF8
            return $mockPath
        }

        # ------------------------------------------------------------------
        # Helper: write a mock gh.ps1 that exits non-zero (simulates gh
        # being unavailable or failing).
        # Returns the path to the mock script.
        # ------------------------------------------------------------------
        $script:WriteBrokenGh = {
            param([string]$WorkDir)
            $mockPath = Join-Path $WorkDir 'gh-broken.ps1'
            $mockScript = @'
Write-Error "gh: command not found"
exit 1
'@
            $mockScript | Set-Content -Path $mockPath -Encoding UTF8
            return $mockPath
        }

        # ------------------------------------------------------------------
        # Helper: invoke Invoke-BackfillCalibration in-process.
        # Returns @{ ExitCode; Output; EntryCount; Entries[] }
        # where Entries[] is the list of entry objects written to review-data.json.
        # ------------------------------------------------------------------
        $script:Invoke = {
            param(
                [string]$WorkDir,
                [string]$GhCliPath,
                [int]$Limit = 10
            )
            $dataFile = Join-Path -Path $WorkDir -ChildPath '.copilot-tracking' -AdditionalChildPath 'calibration', 'review-data.json'

            Push-Location $WorkDir
            $invokeResult = $null
            try {
                $invokeResult = Invoke-BackfillCalibration -GhCliPath $GhCliPath -Limit $Limit
            }
            catch {
                $invokeResult = @{ ExitCode = 1; Output = ''; Error = $_.ToString() }
            }
            finally {
                Pop-Location
            }

            $entries = @()
            if (Test-Path $dataFile) {
                $data = Get-Content $dataFile -Raw | ConvertFrom-Json
                $entries = @($data.entries)
            }

            return @{
                ExitCode   = $invokeResult.ExitCode
                Output     = $invokeResult.Output
                Error      = $invokeResult.Error
                EntryCount = $entries.Count
                Entries    = $entries
            }
        }

        # ------------------------------------------------------------------
        # Helper: build a JSON array of PR objects for use in mock gh output.
        # Each element is a hashtable with number, mergedAt, body.
        # ------------------------------------------------------------------
        $script:BuildPrJson = {
            param([array]$Prs)
            $Prs | ConvertTo-Json -Depth 5 -Compress
        }
    }

    AfterAll {
        try {
            if (Test-Path $script:TempRoot) {
                Remove-Item -Recurse -Force -Path $script:TempRoot
            }
        }
        finally {
            # Suppress any removal errors so AfterAll never throws
        }
    }

    # ======================================================================
    # Context: v2 PR processing
    # ======================================================================
    Context 'v2 PR processing' {

        It 'calls write-calibration-entry.ps1 once per v2 PR' {
            # Arrange: 2 PRs — one v2 (has findings), one v1 (no findings)
            $workDir = & $script:NewWorkDir

            $prs = @(
                @{ number = 42; mergedAt = '2026-03-10T10:00:00Z'; body = $script:V2MetricsBody }
                @{ number = 43; mergedAt = '2026-03-11T11:00:00Z'; body = $script:V1MetricsBody }
            )
            $ghPath = & $script:WriteMockGh -WorkDir $workDir -JsonOutput (& $script:BuildPrJson -Prs $prs)

            # Act
            $result = & $script:Invoke -WorkDir $workDir -GhCliPath $ghPath

            # Assert: one entry written (only for the v2 PR)
            $result.ExitCode  | Should -Be 0 -Because 'success exit expected'
            $result.EntryCount | Should -Be 1 -Because 'only the v2 PR should produce a calibration entry'
        }

        It 'skips PRs with no findings array (v1-only)' {
            # Arrange: 1 PR with pipeline-metrics block but NO findings array
            $workDir = & $script:NewWorkDir

            $prs = @(
                @{ number = 50; mergedAt = '2026-03-12T08:00:00Z'; body = $script:V1MetricsBody }
            )
            $ghPath = & $script:WriteMockGh -WorkDir $workDir -JsonOutput (& $script:BuildPrJson -Prs $prs)

            # Act
            $result = & $script:Invoke -WorkDir $workDir -GhCliPath $ghPath

            # Assert: no entries written
            $result.ExitCode   | Should -Be 0 -Because 'v1-only PRs should be skipped cleanly'
            $result.EntryCount | Should -Be 0 -Because 'v1 PRs have no findings array and must be skipped'
        }

        It 'skips PRs with no pipeline-metrics block at all' {
            # Arrange: 1 PR with no <!-- pipeline-metrics --> block in the body
            $workDir = & $script:NewWorkDir

            $prs = @(
                @{ number = 60; mergedAt = '2026-03-13T09:00:00Z'; body = $script:NoMetricsBody }
            )
            $ghPath = & $script:WriteMockGh -WorkDir $workDir -JsonOutput (& $script:BuildPrJson -Prs $prs)

            # Act
            $result = & $script:Invoke -WorkDir $workDir -GhCliPath $ghPath

            # Assert: no entries written
            $result.ExitCode   | Should -Be 0 -Because 'PRs without metrics blocks should be skipped cleanly'
            $result.EntryCount | Should -Be 0 -Because 'no pipeline-metrics block means nothing to backfill'
        }

        It 'passes created_at (set to the GitHub mergedAt value) in the entry JSON' {
            # Arrange: 1 v2 PR with a known mergedAt timestamp
            $workDir = & $script:NewWorkDir
            $mergedAt = '2026-03-15T14:30:00Z'

            $prs = @(
                @{ number = 70; mergedAt = $mergedAt; body = $script:V2MetricsBody }
            )
            $ghPath = & $script:WriteMockGh -WorkDir $workDir -JsonOutput (& $script:BuildPrJson -Prs $prs)

            # Act
            $result = & $script:Invoke -WorkDir $workDir -GhCliPath $ghPath

            # Assert: one entry with correct created_at
            $result.EntryCount | Should -Be 1 -Because 'one v2 PR should produce one calibration entry'

            $entry = $result.Entries[0]
            # ConvertFrom-Json may auto-convert ISO dates to DateTime; normalize to UTC string for comparison
            ([datetime]$entry.created_at).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') | Should -Be $mergedAt `
                -Because 'created_at in the entry must be set to the GitHub API mergedAt value'
        }

        It 'passes findings from the pipeline-metrics block in the entry JSON' {
            # Arrange: 1 v2 PR with a known finding (id: F1, category: architecture)
            $workDir = & $script:NewWorkDir

            $prs = @(
                @{ number = 80; mergedAt = '2026-03-16T10:00:00Z'; body = $script:V2MetricsBody }
            )
            $ghPath = & $script:WriteMockGh -WorkDir $workDir -JsonOutput (& $script:BuildPrJson -Prs $prs)

            # Act
            $result = & $script:Invoke -WorkDir $workDir -GhCliPath $ghPath

            # Assert: findings[0].id == 'F1' as specified in V2MetricsBody
            $result.EntryCount | Should -Be 1 -Because 'one v2 PR should produce one calibration entry'

            $entry = $result.Entries[0]
            $entry.findings            | Should -Not -BeNullOrEmpty -Because 'findings must be extracted from the metrics block'
            $entry.findings[0].id      | Should -Be 'F1'          -Because 'finding id must match the metrics block content'
            $entry.findings[0].category | Should -Be 'architecture' -Because 'finding category must match the metrics block content'
        }
    }

    # ======================================================================
    # Context: no-op cases
    # ======================================================================
    Context 'no-op cases' {

        It 'exits 0 when gh returns an empty PR list' {
            # Arrange: mock gh returns an empty JSON array
            $workDir = & $script:NewWorkDir

            $ghPath = & $script:WriteMockGh -WorkDir $workDir -JsonOutput '[]'

            # Act
            $result = & $script:Invoke -WorkDir $workDir -GhCliPath $ghPath

            # Assert: exits 0, no entries written
            $result.ExitCode   | Should -Be 0 -Because 'an empty PR list is a valid no-op, not an error'
            $result.EntryCount | Should -Be 0 -Because 'no PRs means no entries to write'
        }

        It 'exits non-zero when gh is unavailable' {
            # Arrange: mock gh that exits 1
            $workDir = & $script:NewWorkDir

            $brokenGhPath = & $script:WriteBrokenGh -WorkDir $workDir

            # Act
            $result = & $script:Invoke -WorkDir $workDir -GhCliPath $brokenGhPath

            # Assert: non-zero exit propagated
            $result.ExitCode | Should -Not -Be 0 `
                -Because 'when gh fails the backfill script must surface the error via non-zero exit'
        }

        It 'returns ExitCode 1 and error message when GhCliPath is not a valid command' {
            # Arrange: a command name that cannot possibly exist on any machine
            # Act
            $result = Invoke-BackfillCalibration -Repo 'owner/repo' -GhCliPath 'gh-definitely-not-installed-xyz'

            # Assert: Get-Command pre-flight guard fires early-return path
            $result.ExitCode | Should -Be 1
            $result.Error    | Should -Match 'not found'
            $result.Output   | Should -BeNullOrEmpty
        }
    }
}
