#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
.SYNOPSIS
    Pester 5 tests for aggregate-review-scores.ps1 -CalibrationFile feature.

.DESCRIPTION
    Contract under test (new -CalibrationFile feature):
      - -CalibrationFile parameter declared with default
        .copilot-tracking/calibration/review-data.json
      - No local file -> existing behavior preserved (same YAML output fields, exit 0)
      - data_source field added to output when calibration file is present
      - Local entries supplement GitHub PR body entries (union merge)
      - Orphan local entries (pr_number not in GitHub merged list) are excluded
      - GitHub mergedAt timestamp is authoritative over local created_at

    Isolation strategy:
      - Each test uses a fresh temp directory.
      - gh-dependent tests (union merge, fallback behavior) are tagged 'requires-gh'
        and skipped when gh CLI is not available.
      - Parameter declaration tests use AST introspection (no gh needed).

    Calibration file schema (follows write-calibration-entry.ps1):
      { "calibration_version": 1, "entries": [ { pr_number, created_at, findings[], summary } ] }
#>

Describe 'aggregate-review-scores.ps1 -CalibrationFile' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:ScriptFile = Join-Path $script:RepoRoot '.github\scripts\aggregate-review-scores.ps1'

        # Master temp root — all per-test dirs live under here
        $script:TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) `
            "pester-aggregate-$([System.Guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path $script:TempRoot -Force | Out-Null

        # Check gh CLI availability (gh-dependent tests are tagged requires-gh)
        $script:GhAvailable = $null -ne (Get-Command gh -ErrorAction SilentlyContinue)

        # ------------------------------------------------------------------
        # Parse script AST for parameter introspection tests (no gh needed)
        # ------------------------------------------------------------------
        $scriptContent = Get-Content -Path $script:ScriptFile -Raw
        $parseErrors = $null
        $script:ScriptAst = [System.Management.Automation.Language.Parser]::ParseInput(
            $scriptContent, [ref]$null, [ref]$parseErrors
        )
        $script:AllParams = $script:ScriptAst.FindAll(
            { $args[0] -is [System.Management.Automation.Language.ParameterAst] }, $true
        )
        $script:ParamNames = $script:AllParams | ForEach-Object { $_.Name.VariablePath.UserPath }

        # ------------------------------------------------------------------
        # Calibration fixture: one valid local entry for a fake PR (pr_number=9901)
        # ------------------------------------------------------------------
        $script:ValidCalibration = [ordered]@{
            calibration_version = 1
            entries             = @(
                [ordered]@{
                    pr_number  = 9901
                    created_at = '2026-01-15T10:00:00Z'
                    findings   = @(
                        [ordered]@{
                            id           = 'F1'
                            category     = 'architecture'
                            judge_ruling = 'sustained'
                            review_stage = 'main'
                        }
                    )
                    summary    = [ordered]@{
                        prosecution_findings = 1
                        pass_1_findings      = 1
                        pass_2_findings      = 0
                        pass_3_findings      = 0
                        defense_disproved    = 0
                        judge_accepted       = 1
                        judge_rejected       = 0
                        judge_deferred       = 0
                    }
                }
            )
        }

        # ------------------------------------------------------------------
        # Orphan calibration fixture: pr_number=99999999 cannot exist in the repo
        # (well above any real PR number). Used to verify orphan removal.
        # ------------------------------------------------------------------
        $script:OrphanCalibration = [ordered]@{
            calibration_version = 1
            entries             = @(
                [ordered]@{
                    pr_number  = 99999999
                    created_at = '2026-03-01T08:00:00Z'
                    findings   = @()
                    summary    = [ordered]@{
                        prosecution_findings = 0
                        pass_1_findings      = 0
                        pass_2_findings      = 0
                        pass_3_findings      = 0
                        defense_disproved    = 0
                        judge_accepted       = 0
                        judge_rejected       = 0
                        judge_deferred       = 0
                    }
                }
            )
        }

        # ------------------------------------------------------------------
        # Stale-timestamp calibration fixture: created_at is ancient (year 2000),
        # giving a decay weight ≈ 0 under the default lambda (0.023 * ~9500 days).
        # Used to verify that GitHub's mergedAt overrides the local value.
        # ------------------------------------------------------------------
        $script:StaleTimestampCalibration = [ordered]@{
            calibration_version = 1
            entries             = @(
                [ordered]@{
                    pr_number  = 9901
                    created_at = '2000-01-01T00:00:00Z'
                    findings   = @(
                        [ordered]@{
                            id           = 'F1'
                            category     = 'architecture'
                            judge_ruling = 'sustained'
                            review_stage = 'main'
                        }
                    )
                    summary    = [ordered]@{
                        prosecution_findings = 1
                        pass_1_findings      = 1
                        pass_2_findings      = 0
                        pass_3_findings      = 0
                        defense_disproved    = 0
                        judge_accepted       = 1
                        judge_rejected       = 0
                        judge_deferred       = 0
                    }
                }
            )
        }

        # ------------------------------------------------------------------
        # Helper: fresh isolated temp dir for a single test
        # ------------------------------------------------------------------
        $script:NewWorkDir = {
            $dir = Join-Path $script:TempRoot ([System.Guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            return $dir
        }

        # ------------------------------------------------------------------
        # Helper: write a calibration JSON file to an absolute path
        # ------------------------------------------------------------------
        $script:WriteCalibrationFile = {
            param([string]$Path, [object]$Data)
            $dir = Split-Path $Path -Parent
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            $Data | ConvertTo-Json -Depth 10 | Set-Content -Path $Path -Encoding UTF8
        }

        # ------------------------------------------------------------------
        # Helper: invoke aggregate-review-scores.ps1 as an external process.
        # $ExtraArgs are appended to the pwsh invocation verbatim.
        # Returns @{ ExitCode; Output (stdout string); Error (stderr string) }
        # ------------------------------------------------------------------
        $script:InvokeAggregate = {
            param([string]$WorkDir, [string[]]$ExtraArgs = @())
            Push-Location $script:RepoRoot
            try {
                $allArgs = @('-NoProfile', '-NonInteractive', '-File', $script:ScriptFile) + $ExtraArgs
                $rawOutput = & pwsh @allArgs 2>&1
                $exitCode = $LASTEXITCODE
                $errLines = ($rawOutput |
                    Where-Object { $_ -is [System.Management.Automation.ErrorRecord] }) -join "`n"
                $outLines = ($rawOutput |
                    Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] }) -join "`n"
                return @{ ExitCode = $exitCode; Output = $outLines; Error = $errLines }
            }
            finally {
                Pop-Location
            }
        }
    }

    AfterAll {
        try {
            if (Test-Path $script:TempRoot) {
                Remove-Item -Recurse -Force -Path $script:TempRoot
            }
        }
        finally {
            # Suppress removal errors so AfterAll never throws
        }
    }

    # ==================================================================
    # Context: -CalibrationFile parameter declaration (AST-based, no gh)
    # ==================================================================
    Context '-CalibrationFile parameter declaration' {

        It 'declares a -CalibrationFile parameter in the param block' {
            # RED: the parameter does not yet exist in aggregate-review-scores.ps1.
            # Strategy: parse the script AST and look for the CalibrationFile param.
            $script:ParamNames | Should -Contain 'CalibrationFile' `
                -Because '-CalibrationFile must be declared so callers can pass a local calibration path'
        }

        It 'defaults -CalibrationFile to .copilot-tracking/calibration/review-data.json' {
            # RED: parameter does not exist yet; this will fail on the BeNullOrEmpty check.
            # Once the parameter is added, the default value text must contain the canonical path.
            $calibParam = $script:AllParams | Where-Object {
                $_.Name.VariablePath.UserPath -eq 'CalibrationFile'
            }
            $calibParam | Should -Not -BeNullOrEmpty `
                -Because '-CalibrationFile must exist before its default can be checked'

            $defaultText = $calibParam.DefaultValue.Extent.Text
            $defaultText | Should -Match '\.copilot-tracking[/\\]calibration[/\\]review-data\.json' `
                -Because 'default path must be .copilot-tracking/calibration/review-data.json'
        }
    }

    # ==================================================================
    # Context: fallback when calibration file is absent
    # Requires gh CLI to reach GitHub and produce any output at all.
    # ==================================================================
    Context 'fallback when calibration file is absent' {

        It 'exits 0 when -CalibrationFile path does not exist' -Tag 'requires-gh' {
            # Requires gh CLI
            # RED: -CalibrationFile is not a recognized parameter; invoking with it
            # produces a parameter-binding error (exit code 1).
            # Once implemented: unknown path -> behave as PR-body-only -> exit 0.
            if (-not $script:GhAvailable) { Set-ItResult -Skipped -Because 'gh CLI not found' }

            $workDir = & $script:NewWorkDir
            $nonExistentPath = Join-Path $workDir 'does-not-exist.json'

            $result = & $script:InvokeAggregate -WorkDir $workDir `
                -ExtraArgs @('-CalibrationFile', $nonExistentPath)

            $result.ExitCode | Should -Be 0 `
                -Because 'a missing calibration file must not abort the script'
        }

        It 'preserves existing YAML output fields when -CalibrationFile path does not exist' -Tag 'requires-gh' {
            # Requires gh CLI
            # RED: parameter-binding error makes exit code non-zero currently.
            # Once implemented: output must still contain canonical fields
            # (insufficient_data: or calibration: plus skipped_prs:), proving
            # that the existing PR-body-parsing path is unchanged.
            if (-not $script:GhAvailable) { Set-ItResult -Skipped -Because 'gh CLI not found' }

            $workDir = & $script:NewWorkDir
            $nonExistentPath = Join-Path $workDir 'does-not-exist.json'

            $result = & $script:InvokeAggregate -WorkDir $workDir `
                -ExtraArgs @('-CalibrationFile', $nonExistentPath)

            $result.ExitCode | Should -Be 0

            # At least one canonical output field must be present
            $hasKnownField = ($result.Output -match 'insufficient_data:') -or
                             ($result.Output -match 'calibration:') -or
                             ($result.Output -match 'skipped_prs:')
            $hasKnownField | Should -BeTrue `
                -Because 'existing YAML output fields must be preserved when CalibrationFile is absent'
        }
    }

    # ==================================================================
    # Context: union merge with local calibration data
    # All require gh CLI to query the real merged PR list.
    # ==================================================================
    Context 'union merge with local calibration data' {

        It 'adds a data_source field to YAML output when calibration file is present' -Tag 'requires-gh' {
            # Requires gh CLI
            # RED: -CalibrationFile is not recognized; parameter binding error.
            # Once implemented: output must contain "data_source:" (value is one of
            # "local", "github", or "merged") when a calibration file is provided.
            if (-not $script:GhAvailable) { Set-ItResult -Skipped -Because 'gh CLI not found' }

            $workDir = & $script:NewWorkDir
            $calibPath = Join-Path $workDir 'calib.json'
            & $script:WriteCalibrationFile -Path $calibPath -Data $script:ValidCalibration

            $result = & $script:InvokeAggregate -WorkDir $workDir `
                -ExtraArgs @('-CalibrationFile', $calibPath)

            $result.ExitCode | Should -Be 0
            $result.Output | Should -Match 'data_source:' `
                -Because 'data_source field must appear in output when a calibration file is provided'
        }

        It 'sets data_source to "github" when calibration file contains only orphan entries' -Tag 'requires-gh' {
            # Requires gh CLI
            # RED: -CalibrationFile not recognized yet.
            # Once implemented: all local entries are orphans (pr_number=99999999 not in
            # GitHub's merged PR list) so they are removed; data comes from GitHub only;
            # data_source must be "github".
            if (-not $script:GhAvailable) { Set-ItResult -Skipped -Because 'gh CLI not found' }

            $workDir = & $script:NewWorkDir
            $calibPath = Join-Path $workDir 'orphan-calib.json'
            & $script:WriteCalibrationFile -Path $calibPath -Data $script:OrphanCalibration

            $result = & $script:InvokeAggregate -WorkDir $workDir `
                -ExtraArgs @('-CalibrationFile', $calibPath)

            $result.ExitCode | Should -Be 0
            $result.Output | Should -Match 'data_source:\s*github' `
                -Because 'orphan entries must be excluded; data must come from GitHub only'
        }

        It 'excludes orphan local entries not present in the GitHub merged PR list' -Tag 'requires-gh' {
            # Requires gh CLI
            # RED: -CalibrationFile not recognized; exit code non-zero.
            # Once implemented: an orphan entry (pr_number=99999999) must not inflate
            # issues_analyzed beyond the GitHub-only baseline.
            if (-not $script:GhAvailable) { Set-ItResult -Skipped -Because 'gh CLI not found' }

            $workDir = & $script:NewWorkDir

            # Baseline: run without -CalibrationFile (GitHub-only, current behavior)
            $baselineResult = & $script:InvokeAggregate -WorkDir $workDir -ExtraArgs @()

            # Run with the orphan-only calibration file
            $calibPath = Join-Path $workDir 'orphan-calib.json'
            & $script:WriteCalibrationFile -Path $calibPath -Data $script:OrphanCalibration
            $withOrphanResult = & $script:InvokeAggregate -WorkDir $workDir `
                -ExtraArgs @('-CalibrationFile', $calibPath)

            # Extract issues_analyzed from both runs
            $baselineMatch = [regex]::Match($baselineResult.Output, 'issues_analyzed:\s*(\d+)')
            $orphanMatch   = [regex]::Match($withOrphanResult.Output, 'issues_analyzed:\s*(\d+)')

            if ($baselineMatch.Success -and $orphanMatch.Success) {
                $orphanMatch.Groups[1].Value | Should -Be $baselineMatch.Groups[1].Value `
                    -Because 'orphan local entries must not inflate issues_analyzed count'
            }
            else {
                # At minimum the parameter must have been accepted (exit 0)
                $withOrphanResult.ExitCode | Should -Be 0 `
                    -Because '-CalibrationFile with orphan-only entries must not crash the script'
            }
        }

        It 'uses GitHub mergedAt timestamp as authoritative over local created_at' -Tag 'requires-gh' {
            # Requires gh CLI
            # RED: -CalibrationFile not recognized; exit code non-zero.
            # Once implemented: the local entry for pr_number=9901 has created_at='2000-01-01'
            # (ancient -> decay weight ≈ 0). If GitHub's mergedAt is used instead, the
            # effective_sample_size contribution for any real recent PR is NOT suppressed.
            # Assertion: effective_sample_size with the stale local file must be >= baseline
            # (stale local timestamp must not reduce existing PR weights).
            if (-not $script:GhAvailable) { Set-ItResult -Skipped -Because 'gh CLI not found' }

            $workDir = & $script:NewWorkDir

            # Baseline: run without -CalibrationFile
            $baselineResult = & $script:InvokeAggregate -WorkDir $workDir -ExtraArgs @()

            # Run with stale-timestamp calibration file
            $calibPath = Join-Path $workDir 'stale-calib.json'
            & $script:WriteCalibrationFile -Path $calibPath -Data $script:StaleTimestampCalibration
            $withStaleResult = & $script:InvokeAggregate -WorkDir $workDir `
                -ExtraArgs @('-CalibrationFile', $calibPath)

            # Extract effective_sample_size from both runs (matches in both output formats)
            $baselineEssMatch = [regex]::Match(
                $baselineResult.Output, 'effective_sample_size:\s*([\d.]+)'
            )
            $withStaleEssMatch = [regex]::Match(
                $withStaleResult.Output, 'effective_sample_size:\s*([\d.]+)'
            )

            if ($baselineEssMatch.Success -and $withStaleEssMatch.Success) {
                $baselineEss = [double]$baselineEssMatch.Groups[1].Value
                $withStaleEss = [double]$withStaleEssMatch.Groups[1].Value
                $withStaleEss | Should -BeGreaterOrEqual $baselineEss `
                    -Because 'GitHub mergedAt must override local stale timestamp; PR weights must not decrease'
            }
            else {
                # At minimum the parameter must have been accepted (exit 0)
                $withStaleResult.ExitCode | Should -Be 0 `
                    -Because '-CalibrationFile with stale timestamps must not crash the script'
            }
        }
    }
}
