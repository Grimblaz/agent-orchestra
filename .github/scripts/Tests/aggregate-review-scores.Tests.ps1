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

    # ==================================================================
    # Context: express-lane injection
    # AST/source-code presence tests — no gh CLI needed.
    # Verifies that both injection paths (local-entries loop and v2 PR-body
    # findings loop) correctly auto-set judge_ruling = 'finding-sustained'
    # for express-lane findings that omit that field.
    # ==================================================================
    Context 'express-lane injection' -Tag 'no-gh' {

        BeforeAll {
            # Array of lines — enables per-line Select-String counts
            $script:ScriptLines = Get-Content -Path $script:ScriptFile
        }

        It 'local-entries path contains the express-lane injection guard' {
            # Verify the guard condition is present somewhere in the script
            ($script:ScriptLines | Select-String "express_lane.*'True'") | Should -Not -BeNullOrEmpty `
                -Because 'the local-entries loop must check express_lane eq True before injecting judge_ruling'
            # Verify the injected value is present
            ($script:ScriptLines | Select-String 'finding-sustained') | Should -Not -BeNullOrEmpty `
                -Because 'the guard must inject judge_ruling = finding-sustained for express-lane findings'
        }

        It 'both injection paths (local-entries and v2 PR-body) are present in the script' {
            ($script:ScriptLines | Select-String 'express_lane.*True').Count |
                Should -BeGreaterOrEqual 2 `
                -Because 'both the local-entries loop (Change B) and v2 PR-body loop (Change C) must contain the express-lane guard'
            ($script:ScriptLines | Select-String 'finding-sustained').Count |
                Should -BeGreaterOrEqual 2 `
                -Because 'both injection paths must set judge_ruling to finding-sustained'
        }

        It '$isSustained treats finding-sustained as a sustained ruling' {
            ($script:ScriptLines | Select-String 'isSustained.*finding-sustained|finding-sustained.*isSustained') |
                Should -Not -BeNullOrEmpty `
                -Because '$isSustained must combine both sustained and finding-sustained so express-lane findings are counted correctly'
        }
    }

    # ==================================================================
    # Context: prosecution_depth output
    # RED TESTS: aggregate-review-scores.ps1 does NOT yet emit a
    # prosecution_depth: section — every test below must fail initially.
    # ==================================================================
    Context 'prosecution_depth output' {

        BeforeAll {
            # Authoritative category list (mirrors $knownCategories in the script)
            $script:DepthCategories = @(
                'architecture', 'security', 'performance', 'pattern',
                'simplicity', 'script-automation', 'documentation-audit'
            )

            # Query merged PRs without pipeline-metrics blocks for calibration entries.
            # These PRs exist in the merged list (not orphaned) but lack body metrics,
            # so the script falls back to calibration entries for their data.
            $allPrJson = & gh pr list --repo 'Grimblaz/copilot-orchestra' --state merged --limit 100 --json number,body 2>$null
            $script:NonMetricsPrNumbers = if ($allPrJson) {
                @(($allPrJson | ConvertFrom-Json) |
                    Where-Object { $_.body -notmatch 'pipeline-metrics' } |
                    ForEach-Object { [int]$_.number })
            } else {
                @(9901)  # fallback if gh fails
            }

            # Query a public repo that has no pipeline-metrics in any PR body,
            # giving pure calibration-only data for isolation tests.
            $cleanPrJson = & gh pr list --repo 'github/docs' --state merged --limit 10 --json number 2>$null
            $script:CleanRepoPrNumbers = if ($cleanPrJson) {
                @(($cleanPrJson | ConvertFrom-Json) | ForEach-Object { [int]$_.number })
            } else {
                @(9901)  # fallback if gh fails
            }

            # ---------------------------------------------------------------
            # Helper: generate findings array for a single category with
            # specified sustained / defense-sustained counts.
            # ---------------------------------------------------------------
            $script:MakeCategoryFindings = {
                param([string]$Category, [int]$Sustained, [int]$DefenseSustained)
                $list = [System.Collections.Generic.List[object]]::new()
                for ($i = 1; $i -le $Sustained; $i++) {
                    $list.Add([ordered]@{
                        id           = "F-${Category}-s${i}"
                        category     = $Category
                        judge_ruling = 'finding-sustained'
                        severity     = 'medium'
                        points       = 5
                        review_stage = 'main'
                    })
                }
                for ($i = 1; $i -le $DefenseSustained; $i++) {
                    $list.Add([ordered]@{
                        id           = "F-${Category}-d${i}"
                        category     = $Category
                        judge_ruling = 'defense-sustained'
                        severity     = 'medium'
                        points       = 5
                        review_stage = 'main'
                    })
                }
                return , $list.ToArray()
            }

            # ---------------------------------------------------------------
            # Helper: build a calibration object with entries and optional
            # prosecution-depth overlay fields.
            # ---------------------------------------------------------------
            $script:BuildDepthCalibration = {
                param(
                    [object[]]$Findings,
                    [string]$Override = $null,
                    [object[]]$ReactivationEvents = $null,
                    [object]$DepthState = $null,
                    [int[]]$PrNumbers = @(9901)
                )
                $entries = @()
                foreach ($prNum in $PrNumbers) {
                    $entries += [ordered]@{
                        pr_number  = $prNum
                        created_at = '2026-03-01T10:00:00Z'
                        findings   = $Findings
                        summary    = [ordered]@{
                            prosecution_findings = $Findings.Count
                            pass_1_findings      = $Findings.Count
                            pass_2_findings      = 0
                            pass_3_findings      = 0
                            defense_disproved    = 0
                            judge_accepted       = $Findings.Count
                            judge_rejected       = 0
                            judge_deferred       = 0
                        }
                    }
                }
                $calib = [ordered]@{
                    calibration_version = 1
                    entries             = $entries
                }
                if (-not [string]::IsNullOrEmpty($Override)) {
                    $calib['prosecution_depth_override'] = $Override
                }
                if ($null -ne $ReactivationEvents) {
                    $calib['re_activation_events'] = $ReactivationEvents
                }
                if ($null -ne $DepthState) {
                    $calib['prosecution_depth_state'] = $DepthState
                }
                return $calib
            }
        }

        # ------ AST-based test (no-gh) ------

        It 'script help block no longer claims READ-ONLY' -Tag 'no-gh' {
            # RED: the .DESCRIPTION section currently contains "READ-ONLY".
            # Implementation will update it to reflect prosecution_depth_state writes.
            $content = Get-Content -Path $script:ScriptFile -Raw
            $content | Should -Not -cMatch 'READ-ONLY' `
                -Because 'script description must be updated to reflect prosecution_depth_state writes'
        }

        # ------ Execution tests (requires-gh) ------

        It 'emits prosecution_depth section in YAML output' -Tag 'requires-gh' {
            # RED: script does not yet emit prosecution_depth: in output.
            if (-not $script:GhAvailable) { Set-ItResult -Skipped -Because 'gh CLI not found' }

            $workDir = & $script:NewWorkDir
            $findings = @(
                [ordered]@{ id = 'F1'; category = 'architecture'; judge_ruling = 'finding-sustained'
                            severity = 'medium'; points = 5; review_stage = 'main' },
                [ordered]@{ id = 'F2'; category = 'security'; judge_ruling = 'defense-sustained'
                            severity = 'medium'; points = 5; review_stage = 'main' }
            )
            $calib = & $script:BuildDepthCalibration -Findings $findings
            $calibPath = Join-Path $workDir 'depth-calib.json'
            & $script:WriteCalibrationFile -Path $calibPath -Data $calib

            $result = & $script:InvokeAggregate -WorkDir $workDir `
                -ExtraArgs @('-CalibrationFile', $calibPath)

            $result.ExitCode | Should -Be 0
            $result.Output | Should -Match 'prosecution_depth:' `
                -Because 'prosecution_depth section must appear in YAML output when v2 findings data exists'
        }

        It 'emits all 7 known categories with recommendation, sustain_rate, effective_count, sufficient_data, re_activated' -Tag 'requires-gh' {
            # RED: prosecution_depth section does not exist yet; first assertion fails.
            if (-not $script:GhAvailable) { Set-ItResult -Skipped -Because 'gh CLI not found' }

            $workDir = & $script:NewWorkDir
            $findings = @(
                [ordered]@{ id = 'F1'; category = 'architecture'; judge_ruling = 'finding-sustained'
                            severity = 'medium'; points = 5; review_stage = 'main' }
            )
            $calib = & $script:BuildDepthCalibration -Findings $findings
            $calibPath = Join-Path $workDir 'depth-calib.json'
            & $script:WriteCalibrationFile -Path $calibPath -Data $calib

            $result = & $script:InvokeAggregate -WorkDir $workDir `
                -ExtraArgs @('-CalibrationFile', $calibPath)

            $result.ExitCode | Should -Be 0

            # Unique to prosecution_depth — fails in RED
            $result.Output | Should -Match 'prosecution_depth:' `
                -Because 'prosecution_depth section must be emitted before checking per-category fields'

            foreach ($cat in $script:DepthCategories) {
                $result.Output | Should -Match "(?s)prosecution_depth:.*?${cat}:" `
                    -Because "category '$cat' must appear under prosecution_depth"
            }
            $result.Output | Should -Match 'recommendation:' `
                -Because 'recommendation field must appear in prosecution_depth categories'
            $result.Output | Should -Match 're_activated:' `
                -Because 're_activated field must appear in prosecution_depth categories'
        }

        It 'reports recommendation skip when sustain_rate below 0.05 and effective_count at least 30' -Tag 'requires-gh' {
            # Fixture: architecture — 1 sustained + 34 defense-sustained per non-metrics PR
            # Calibration dominates real data → sustain_rate ≈ 0.029 (< 0.05)
            if (-not $script:GhAvailable) { Set-ItResult -Skipped -Because 'gh CLI not found' }

            $workDir = & $script:NewWorkDir
            $findings = & $script:MakeCategoryFindings 'architecture' 1 34
            $calib = & $script:BuildDepthCalibration -Findings $findings -PrNumbers $script:NonMetricsPrNumbers
            $calibPath = Join-Path $workDir 'skip-calib.json'
            & $script:WriteCalibrationFile -Path $calibPath -Data $calib

            $result = & $script:InvokeAggregate -WorkDir $workDir `
                -ExtraArgs @('-CalibrationFile', $calibPath)

            $result.ExitCode | Should -Be 0
            $result.Output | Should -Match '(?s)prosecution_depth:.*?architecture:\s+recommendation:\s*skip' `
                -Because 'sustain_rate < 0.05 with effective_count >= 30 must produce recommendation: skip'
        }

        It 'reports recommendation light when sustain_rate below 0.15 and effective_count at least 20' -Tag 'requires-gh' {
            # Fixture: security — 3 sustained + 22 defense-sustained per non-metrics PR
            # Calibration dominates real data → sustain_rate ≈ 0.12 (< 0.15, >= 0.05)
            if (-not $script:GhAvailable) { Set-ItResult -Skipped -Because 'gh CLI not found' }

            $workDir = & $script:NewWorkDir
            $findings = & $script:MakeCategoryFindings 'security' 3 22
            $calib = & $script:BuildDepthCalibration -Findings $findings -PrNumbers $script:NonMetricsPrNumbers
            $calibPath = Join-Path $workDir 'light-calib.json'
            & $script:WriteCalibrationFile -Path $calibPath -Data $calib

            $result = & $script:InvokeAggregate -WorkDir $workDir `
                -ExtraArgs @('-CalibrationFile', $calibPath)

            $result.ExitCode | Should -Be 0
            $result.Output | Should -Match '(?s)prosecution_depth:.*?security:\s+recommendation:\s*light' `
                -Because 'sustain_rate < 0.15 with effective_count >= 20 must produce recommendation: light'
        }

        It 'reports recommendation full when sustain_rate >= 0.15' -Tag 'requires-gh' {
            # Fixture: performance — 8 sustained + 12 defense-sustained per non-metrics PR
            # Calibration dominates real data → sustain_rate ≈ 0.40 (>= 0.15)
            if (-not $script:GhAvailable) { Set-ItResult -Skipped -Because 'gh CLI not found' }

            $workDir = & $script:NewWorkDir
            $findings = & $script:MakeCategoryFindings 'performance' 8 12
            $calib = & $script:BuildDepthCalibration -Findings $findings -PrNumbers $script:NonMetricsPrNumbers
            $calibPath = Join-Path $workDir 'full-calib.json'
            & $script:WriteCalibrationFile -Path $calibPath -Data $calib

            $result = & $script:InvokeAggregate -WorkDir $workDir `
                -ExtraArgs @('-CalibrationFile', $calibPath)

            $result.ExitCode | Should -Be 0
            $result.Output | Should -Match '(?s)prosecution_depth:.*?performance:\s+recommendation:\s*full' `
                -Because 'sustain_rate >= 0.15 must produce recommendation: full'
        }

        It 'reports recommendation full with sufficient_data false when effective_count < 20' -Tag 'requires-gh' {
            # Fixture: architecture findings only → simplicity gets data only from real
            # pipeline-metrics PRs (small effective_count, < 20 → insufficient data)
            if (-not $script:GhAvailable) { Set-ItResult -Skipped -Because 'gh CLI not found' }

            $workDir = & $script:NewWorkDir
            $findings = & $script:MakeCategoryFindings 'architecture' 1 0
            $calib = & $script:BuildDepthCalibration -Findings $findings -PrNumbers $script:NonMetricsPrNumbers
            $calibPath = Join-Path $workDir 'insuff-calib.json'
            & $script:WriteCalibrationFile -Path $calibPath -Data $calib

            $result = & $script:InvokeAggregate -WorkDir $workDir `
                -ExtraArgs @('-CalibrationFile', $calibPath)

            $result.ExitCode | Should -Be 0
            $result.Output | Should -Match '(?s)prosecution_depth:.*?simplicity:\s+recommendation:\s*full' `
                -Because 'insufficient data (effective_count < 20) must default to recommendation: full'
            $result.Output | Should -Match '(?s)prosecution_depth:.*?simplicity:.*?sufficient_data:\s*false' `
                -Because 'effective_count < 20 must set sufficient_data: false'
        }

        It 'reports recommendation full with effective_count 0.0 for categories absent from data' -Tag 'requires-gh' {
            # Uses github/docs (no pipeline-metrics) for pure calibration isolation.
            # Architecture findings only → all other categories have effective_count 0.0.
            if (-not $script:GhAvailable) { Set-ItResult -Skipped -Because 'gh CLI not found' }

            $workDir = & $script:NewWorkDir
            $findings = @(
                [ordered]@{ id = 'F1'; category = 'architecture'; judge_ruling = 'finding-sustained'
                            severity = 'medium'; points = 5; review_stage = 'main' }
            )
            $calib = & $script:BuildDepthCalibration -Findings $findings -PrNumbers $script:CleanRepoPrNumbers
            $calibPath = Join-Path $workDir 'zero-calib.json'
            & $script:WriteCalibrationFile -Path $calibPath -Data $calib

            $result = & $script:InvokeAggregate -WorkDir $workDir `
                -ExtraArgs @('-CalibrationFile', $calibPath, '-Repo', 'github/docs', '-Limit', '10')

            $result.ExitCode | Should -Be 0
            $result.Output | Should -Match '(?s)prosecution_depth:.*?documentation-audit:\s+recommendation:\s*full' `
                -Because 'categories absent from finding data must default to recommendation: full'
            $result.Output | Should -Match '(?s)prosecution_depth:.*?documentation-audit:.*?effective_count:\s*0\.0' `
                -Because 'categories with no findings must report effective_count: 0.0'
        }

        It 'emits override_active true and forces all categories to full when prosecution_depth_override is set' -Tag 'requires-gh' {
            # RED: prosecution_depth section does not exist yet.
            if (-not $script:GhAvailable) { Set-ItResult -Skipped -Because 'gh CLI not found' }

            $workDir = & $script:NewWorkDir
            $findings = @(
                [ordered]@{ id = 'F1'; category = 'architecture'; judge_ruling = 'finding-sustained'
                            severity = 'medium'; points = 5; review_stage = 'main' }
            )
            $calib = & $script:BuildDepthCalibration -Findings $findings -Override 'full'
            $calibPath = Join-Path $workDir 'override-calib.json'
            & $script:WriteCalibrationFile -Path $calibPath -Data $calib

            $result = & $script:InvokeAggregate -WorkDir $workDir `
                -ExtraArgs @('-CalibrationFile', $calibPath)

            $result.ExitCode | Should -Be 0
            $result.Output | Should -Match '(?s)prosecution_depth:\s+override_active:\s*true' `
                -Because 'prosecution_depth_override in calibration file must set override_active: true'
            foreach ($cat in $script:DepthCategories) {
                $result.Output | Should -Match "(?s)prosecution_depth:.*?${cat}:\s+recommendation:\s*full" `
                    -Because "override must force category '$cat' to recommendation: full"
            }
        }

        It 'reports recommendation full and re_activated true when a re-activation event is active' -Tag 'requires-gh' {
            # RED: prosecution_depth section does not exist yet.
            # Fixture: re-activation event for 'pattern' with expires_at_pr=999999
            if (-not $script:GhAvailable) { Set-ItResult -Skipped -Because 'gh CLI not found' }

            $workDir = & $script:NewWorkDir
            $findings = @(
                [ordered]@{ id = 'F1'; category = 'architecture'; judge_ruling = 'finding-sustained'
                            severity = 'medium'; points = 5; review_stage = 'main' }
            )
            $reactivationEvents = @(
                [ordered]@{
                    category        = 'pattern'
                    triggered_at_pr = 100
                    expires_at_pr   = 999999
                    trigger_source  = 'manual_override'
                    created_at      = '2026-03-01T10:00:00Z'
                }
            )
            $calib = & $script:BuildDepthCalibration -Findings $findings `
                -ReactivationEvents $reactivationEvents
            $calibPath = Join-Path $workDir 'reactivation-calib.json'
            & $script:WriteCalibrationFile -Path $calibPath -Data $calib

            $result = & $script:InvokeAggregate -WorkDir $workDir `
                -ExtraArgs @('-CalibrationFile', $calibPath)

            $result.ExitCode | Should -Be 0
            $result.Output | Should -Match '(?s)prosecution_depth:.*?pattern:\s+recommendation:\s*full' `
                -Because 'active re-activation event must force recommendation: full'
            $result.Output | Should -Match '(?s)prosecution_depth:.*?pattern:.*?re_activated:\s*true' `
                -Because 'active re-activation event must set re_activated: true'
        }

        It 'applies time-decay when skip_first_observed_at exceeds 90 days' -Tag 'requires-gh' {
            # RED: prosecution_depth section does not exist yet.
            # Fixture: architecture skip_first_observed_at is 100 days ago (> 90-day default)
            if (-not $script:GhAvailable) { Set-ItResult -Skipped -Because 'gh CLI not found' }

            $workDir = & $script:NewWorkDir
            $staleDate = (Get-Date).AddDays(-100).ToString('o')
            $findings = @(
                [ordered]@{ id = 'F1'; category = 'architecture'; judge_ruling = 'finding-sustained'
                            severity = 'medium'; points = 5; review_stage = 'main' }
            )
            $depthState = [ordered]@{
                architecture = [ordered]@{
                    skip_first_observed_at = $staleDate
                }
            }
            $calib = & $script:BuildDepthCalibration -Findings $findings -DepthState $depthState
            $calibPath = Join-Path $workDir 'timedecay-calib.json'
            & $script:WriteCalibrationFile -Path $calibPath -Data $calib

            $result = & $script:InvokeAggregate -WorkDir $workDir `
                -ExtraArgs @('-CalibrationFile', $calibPath)

            $result.ExitCode | Should -Be 0
            $result.Output | Should -Match '(?s)prosecution_depth:.*?architecture:\s+recommendation:\s*light' `
                -Because 'skip_first_observed_at > 90 days must decay from skip to light'
            $result.Output | Should -Match '(?s)prosecution_depth:.*?architecture:.*?re_activated:\s*true' `
                -Because 'time-decay re-activation must set re_activated: true'
        }

        It 'priority chain: override > re-activation > time-decay > insufficient-data > threshold' -Tag 'requires-gh' {
            # RED: prosecution_depth section does not exist yet.
            # Fixture: override=full AND re-activation event AND time-decay state
            # Override must win: all categories forced to full, override_active: true
            if (-not $script:GhAvailable) { Set-ItResult -Skipped -Because 'gh CLI not found' }

            $workDir = & $script:NewWorkDir
            $findings = @(
                [ordered]@{ id = 'F1'; category = 'architecture'; judge_ruling = 'finding-sustained'
                            severity = 'medium'; points = 5; review_stage = 'main' }
            )
            $reactivationEvents = @(
                [ordered]@{
                    category        = 'security'
                    triggered_at_pr = 100
                    expires_at_pr   = 999999
                    trigger_source  = 'manual_override'
                    created_at      = '2026-03-01T10:00:00Z'
                }
            )
            $staleDate = (Get-Date).AddDays(-100).ToString('o')
            $depthState = [ordered]@{
                performance = [ordered]@{
                    skip_first_observed_at = $staleDate
                }
            }
            $calib = & $script:BuildDepthCalibration -Findings $findings `
                -Override 'full' -ReactivationEvents $reactivationEvents -DepthState $depthState
            $calibPath = Join-Path $workDir 'priority-calib.json'
            & $script:WriteCalibrationFile -Path $calibPath -Data $calib

            $result = & $script:InvokeAggregate -WorkDir $workDir `
                -ExtraArgs @('-CalibrationFile', $calibPath)

            $result.ExitCode | Should -Be 0
            # Override wins: override_active must be true
            $result.Output | Should -Match '(?s)prosecution_depth:\s+override_active:\s*true' `
                -Because 'override takes highest priority — override_active must be true'
            # All categories forced to full by override
            foreach ($cat in $script:DepthCategories) {
                $result.Output | Should -Match "(?s)prosecution_depth:.*?${cat}:\s+recommendation:\s*full" `
                    -Because "override must force '$cat' to full regardless of re-activation or time-decay signals"
            }
        }

        # ==================================================================
        # Context: write-back persistence
        # Verifies that the calibration file is updated on disk after an
        # aggregate run that modifies prosecution_depth_state or prunes
        # expired re-activation events.
        # ==================================================================
        Context 'write-back persistence' {

            It 'write-back: entering skip writes skip_first_observed_at to calibration file' -Tag 'requires-gh' {
                if (-not $script:GhAvailable) { Set-ItResult -Skipped -Because 'gh CLI not found' }

                # ARRANGE: calibration where pattern enters skip
                # (1 sustained + 34 defense-sustained -> sustain_rate ~= 0.029 < 0.05, effective_count >= 30)
                $workDir = & $script:NewWorkDir
                $findings = & $script:MakeCategoryFindings 'pattern' 1 34
                $calib = & $script:BuildDepthCalibration -Findings $findings -PrNumbers $script:NonMetricsPrNumbers
                $calibPath = Join-Path $workDir 'skip-writeback.json'
                & $script:WriteCalibrationFile -Path $calibPath -Data $calib

                # ACT
                $result = & $script:InvokeAggregate -WorkDir $workDir `
                    -ExtraArgs @('-CalibrationFile', $calibPath)

                # ASSERT: fixture produced skip recommendation (confirms write-back path was entered)
                $result.ExitCode | Should -Be 0
                $result.Output | Should -Match '(?s)prosecution_depth:.*?pattern:\s+recommendation:\s*skip' `
                    -Because 'fixture must produce skip recommendation so write-back path is triggered'

                # ASSERT: calibration file updated with skip_first_observed_at
                $readBack = Get-Content $calibPath -Raw | ConvertFrom-Json -AsHashtable
                $readBack | Should -Not -BeNullOrEmpty `
                    -Because 'calibration file must still be readable after run'
                $readBack['prosecution_depth_state'] | Should -Not -BeNullOrEmpty `
                    -Because 'prosecution_depth_state must be written to calibration file when a category enters skip'
                $readBack['prosecution_depth_state']['pattern'] | Should -Not -BeNullOrEmpty `
                    -Because 'pattern state must be persisted when the category enters skip'
                $skipDate = $readBack['prosecution_depth_state']['pattern']['skip_first_observed_at']
                $skipDate | Should -Not -BeNullOrEmpty `
                    -Because 'skip_first_observed_at must be written when a category first enters skip'
                { [datetime]$skipDate } | Should -Not -Throw `
                    -Because 'skip_first_observed_at must be a valid datetime string'
            }

            It 'write-back: transitioning from skip to full clears skip_first_observed_at from calibration file' -Tag 'requires-gh' {
                if (-not $script:GhAvailable) { Set-ItResult -Skipped -Because 'gh CLI not found' }

                # ARRANGE: pre-seeded skip state for pattern, but findings now show high sustain_rate
                # (8 sustained + 12 defense-sustained -> sustain_rate = 0.4 >= 0.15 -> full)
                $workDir = & $script:NewWorkDir
                $findings = & $script:MakeCategoryFindings 'pattern' 8 12
                $depthState = [ordered]@{
                    pattern = [ordered]@{
                        skip_first_observed_at = '2026-02-01T00:00:00Z'
                    }
                }
                $calib = & $script:BuildDepthCalibration -Findings $findings `
                    -PrNumbers $script:NonMetricsPrNumbers -DepthState $depthState
                $calibPath = Join-Path $workDir 'leave-skip-writeback.json'
                & $script:WriteCalibrationFile -Path $calibPath -Data $calib

                # ACT
                $result = & $script:InvokeAggregate -WorkDir $workDir `
                    -ExtraArgs @('-CalibrationFile', $calibPath)

                # ASSERT: pattern recommendation is now full (exited skip)
                $result.ExitCode | Should -Be 0
                $result.Output | Should -Match '(?s)prosecution_depth:.*?pattern:\s+recommendation:\s*full' `
                    -Because 'sustain_rate >= 0.15 must produce recommendation: full (pattern exited skip)'

                # ASSERT: skip_first_observed_at cleared from calibration file
                $readBack = Get-Content $calibPath -Raw | ConvertFrom-Json -AsHashtable
                $readBack | Should -Not -BeNullOrEmpty `
                    -Because 'calibration file must still be readable after run'
                $depthStateAfter = $readBack['prosecution_depth_state']
                if ($null -ne $depthStateAfter -and $null -ne $depthStateAfter['pattern']) {
                    $depthStateAfter['pattern']['skip_first_observed_at'] | Should -BeNullOrEmpty `
                        -Because 'skip_first_observed_at must be cleared when category exits skip'
                }
                # If prosecution_depth_state has no pattern key at all, the contract is also satisfied
            }

            It 'write-back: expired re-activation events are pruned on write-back' -Tag 'requires-gh' {
                if (-not $script:GhAvailable) { Set-ItResult -Skipped -Because 'gh CLI not found' }

                # ARRANGE: two re-activation events (one active, one expired) plus a skip-entering
                # category fixture so that $depthStateChanged is set and write-back runs.
                # pattern enters skip -> $depthStateChanged = $true -> write-back triggers event pruning.
                $workDir = & $script:NewWorkDir
                $findings = & $script:MakeCategoryFindings 'pattern' 1 34  # pattern -> skip
                $reactivationEvents = @(
                    [ordered]@{
                        category        = 'architecture'
                        triggered_at_pr = 90
                        expires_at_pr   = 999999  # far future — stays active
                        trigger_source  = 'manual_override'
                        created_at      = '2026-03-01T10:00:00Z'
                    },
                    [ordered]@{
                        category        = 'security'
                        triggered_at_pr = 1
                        expires_at_pr   = 2       # PR 2 is already merged — expired
                        trigger_source  = 'manual_override'
                        created_at      = '2020-01-01T00:00:00Z'
                    }
                )
                $calib = & $script:BuildDepthCalibration -Findings $findings `
                    -PrNumbers $script:NonMetricsPrNumbers -ReactivationEvents $reactivationEvents
                $calibPath = Join-Path $workDir 'prune-events-writeback.json'
                & $script:WriteCalibrationFile -Path $calibPath -Data $calib

                # ACT
                $result = & $script:InvokeAggregate -WorkDir $workDir `
                    -ExtraArgs @('-CalibrationFile', $calibPath)

                # ASSERT: script succeeded
                $result.ExitCode | Should -Be 0

                # ASSERT: calibration file re_activation_events contains only the active event
                $readBack = Get-Content $calibPath -Raw | ConvertFrom-Json -AsHashtable
                $eventsAfter = $readBack['re_activation_events']
                $eventsAfter | Should -Not -BeNullOrEmpty `
                    -Because 'the active re-activation event must survive pruning'
                $eventsAfter.Count | Should -Be 1 `
                    -Because 'the expired event (expires_at_pr=2) must be pruned; only the active event survives'
                [int]$eventsAfter[0]['expires_at_pr'] | Should -Be 999999 `
                    -Because 'the surviving event must be the active one with expires_at_pr=999999'
            }

            It 'writes time-decay synthetic re-activation event to calibration file' -Tag 'requires-gh' {
                if (-not $script:GhAvailable) { Set-ItResult -Skipped -Because 'gh CLI not found' }

                # ARRANGE: architecture has a stale skip_first_observed_at (100 days ago) and
                # skip-threshold findings (sustain_rate ~0.029 < 0.05, dominated by NonMetricsPRs).
                # Time-decay must fire, promote the recommendation to light, and persist a
                # synthetic re-activation event to the calibration file on disk.
                $workDir = & $script:NewWorkDir
                $staleDate = (Get-Date).AddDays(-100).ToString('o')
                $findings = & $script:MakeCategoryFindings 'architecture' 1 34
                $depthState = [ordered]@{
                    architecture = [ordered]@{
                        skip_first_observed_at = $staleDate
                    }
                }
                $calib = & $script:BuildDepthCalibration -Findings $findings `
                    -PrNumbers $script:NonMetricsPrNumbers -DepthState $depthState
                $calibPath = Join-Path $workDir 'timedecay-writeback.json'
                & $script:WriteCalibrationFile -Path $calibPath -Data $calib

                # ACT
                $result = & $script:InvokeAggregate -WorkDir $workDir `
                    -ExtraArgs @('-CalibrationFile', $calibPath)

                # ASSERT: time-decay promoted architecture to light (confirming the write-back path was entered)
                $result.ExitCode | Should -Be 0
                $result.Output | Should -Match '(?s)prosecution_depth:.*?architecture:\s+recommendation:\s*light' `
                    -Because 'stale skip_first_observed_at must time-decay architecture from skip to light'

                # ASSERT: synthetic re-activation event persisted to calibration file
                $readBack = Get-Content $calibPath -Raw | ConvertFrom-Json -AsHashtable
                $readBack | Should -Not -BeNullOrEmpty `
                    -Because 'calibration file must still be readable after run'
                $eventsAfter = $readBack['re_activation_events']
                $eventsAfter | Should -Not -BeNullOrEmpty `
                    -Because 'time-decay must persist a synthetic re-activation event to the calibration file'
                $eventsAfter.Count | Should -Be 1 `
                    -Because 'exactly one synthetic event must be written for the architecture time-decay trigger'
                $eventsAfter[0]['category'] | Should -Be 'architecture' `
                    -Because 'the synthetic event must record the category that triggered time-decay'
                $eventsAfter[0]['trigger_source'] | Should -Be 'time_decay' `
                    -Because 'trigger_source must be time_decay for a time-decay synthetic event'
                [int]$eventsAfter[0]['triggered_at_pr'] | Should -BeGreaterThan 0 `
                    -Because 'triggered_at_pr must equal the max merged PR number (a positive integer)'
                [int]$eventsAfter[0]['expires_at_pr'] | Should -Be ([int]$eventsAfter[0]['triggered_at_pr'] + 50) `
                    -Because 'expires_at_pr must be triggered_at_pr + 50 as computed by the time-decay logic'
            }
        }
    }
}
